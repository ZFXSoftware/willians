namespace :conciliacao do
  desc "Nota por nota de um repasse: a fração do pacote e o que ela produz (SOMENTE LEITURA)"
  task rateio_do_pacote: :environment do
    # "1 nota de pacote entrou pela fração que coube a este repasse" é mecanismo
    # legítimo: no Mercado Livre o comprador leva dois itens numa compra, o
    # vendedor emite UMA nota, e o dinheiro de cada item é liberado separado —
    # às vezes em repasses diferentes. Comparar o repasse que pagou metade contra
    # o título inteiro mostraria diferença que não existe.
    #
    # Mas é RATEIO, não medição: a nota não diz quanto vale cada item, e o
    # denominador é a soma dos recebíveis LIGADOS àquela nota no nosso banco.
    # Venda do pacote que não foi ingerida, ou que existe e não foi vinculada,
    # encolhe o denominador — a fração sobe, e o título entra por mais do que
    # este repasse pagou.
    #
    # No #42 a diferença total é R$ 3,98 com R$ 489,55 de vendas sem nota dentro
    # dela: aritmeticamente, o resto tem de ser NEGATIVO em R$ 485. Título
    # valendo mais que a venda que o lastreia. Esta tarefa mostra de qual nota
    # vem, em vez de eu escolher a hipótese por dedução.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    id = ENV["REPASSE"].to_i

    lote = id.positive? ? PayoutBatch.find_by(tenant_id: tenant.id, id: id) : nil

    next puts("Use REPASSE=<id>.") if lote.blank?

    unidades = lote.financial_entry_allocations.filter_map(&:receivable_unit).uniq

    linhas = FinancialEntry
               .where(tenant_id: tenant.id, external_id: unidades.map(&:external_id))
               .pluck(:external_id, :raw_payload)
               .to_h { |externo, cru| [ externo, cru.is_a?(Hash) ? cru : {} ] }

    # BRUTO CRU, que é o que o motor compara com o título.
    #
    # A primeira versão desta tarefa somava o bruto MENOS o parcelamento, porque eu
    # a escrevi durante a hipótese de que o parcelamento estava somado ao bruto.
    # Resultado: todo delta saía exatamente igual ao parcelamento, e eu quase li
    # isso como achado. A sonda precisa medir a mesma coisa que o código, senão
    # mede a minha suposição.
    bruto = ->(lista) { lista.sum(BigDecimal("0")) { |u| u.gross_amount.to_d } }

    encargo = lambda do |lista, chave|
      lista.sum(BigDecimal("0")) { |u| linhas[u.external_id].to_h[chave].to_d.abs }
    end

    por_nota = unidades.select(&:invoice).group_by(&:invoice)

    # O denominador COMPLETO: todos os recebíveis ligados à nota, em qualquer
    # repasse. É o mesmo que `fracoes_das_notas` usa.
    todos = ReceivableUnit
              .where(tenant_id: tenant.id, invoice_id: por_nota.keys.map(&:id))
              .group(:invoice_id)
              .sum(:gross_amount)

    # E quantos desses recebíveis estão em ALGUM repasse: venda ligada à nota mas
    # que nenhum repasse pagou ainda infla o denominador e encolhe a fração.
    em_repasse = FinancialEntryAllocation
                   .where(tenant_id: tenant.id)
                   .where.not(payout_batch_id: nil)
                   .joins(:receivable_unit)
                   .where(receivable_units: { invoice_id: por_nota.keys.map(&:id) })
                   .distinct
                   .pluck(:receivable_unit_id)
                   .to_set

    puts "Repasse ##{lote.id}, pago em #{lote.paid_at&.to_date}"
    puts format("  bruto do repasse: R$ %.2f", lote.gross_amount.to_d)
    puts format("  vendas no repasse: %d (%d com nota)", unidades.size, unidades.count(&:invoice))
    puts

    total_delta = BigDecimal("0")

    suspeitas = []

    tabela = []

    por_nota.each do |nota, lista|
      aqui = bruto.call(lista)

      total = todos[nota.id].to_d

      fracao = total.positive? ? (lista.sum(BigDecimal("0")) { |u| u.gross_amount.to_d } / total) : BigDecimal("1")

      aplicado = (nota.total_amount.to_d * fracao).round(2)

      # O que este repasse pagou daquela nota, contra o que o título cobra dele.
      delta = (aqui - aplicado).round(2)

      total_delta += delta

      todas = ReceivableUnit.where(tenant_id: tenant.id, invoice_id: nota.id).to_a

      orfas = todas.reject { |u| em_repasse.include?(u.id) }

      marca = if fracao < 1 && orfas.any?
        " <- fração parcial E #{orfas.size} venda(s) sem repasse"
      elsif delta.abs > 1
        " <- título #{delta.negative? ? 'MAIOR' : 'menor'} que a venda"
      else
        ""
      end

      suspeitas << [ nota, lista, todas, orfas, fracao, aplicado, delta ] if delta.abs > 1 && suspeitas.size < 6

      tabela << [ delta, format("  %-10s %5d %11.2f %11.2f %11.2f %7.4f %11.2f %11.2f %9.2f %9.2f%s",
                                nota.number, lista.size, nota.total_amount.to_d, aqui, total,
                                fracao, aplicado, delta,
                                encargo.call(lista, "FINANCING_FEE_AMOUNT"),
                                encargo.call(lista, "COUPON_AMOUNT"), marca) ]
    end

    # Ordenado pelo DESVIO, não pelo número da nota: com 161 notas, a que importa
    # não está em ordem alfabética.
    puts format("  %-10s %5s %11s %11s %11s %7s %11s %11s %9s %9s",
                "NF", "vendas", "nota", "bruto aqui", "bruto tot", "fração", "título×fr",
                "delta", "parcel.", "cupom")

    tabela.sort_by { |delta, _| delta }.first(12).each { |_, linha| puts linha }

    puts "  ..." if tabela.size > 24

    tabela.sort_by { |delta, _| -delta }.first(12).reverse_each { |_, linha| puts linha }

    puts
    puts format("Soma dos deltas (bruto aqui − título aplicado): R$ %.2f", total_delta)
    puts format("Vendas SEM nota neste repasse:                  R$ %.2f",
                bruto.call(unidades.reject(&:invoice)))
    puts format("Diferença gravada do repasse:                   R$ %.2f",
                ConciliacaoRegistro.where(tenant_id: tenant.id, payout_batch_id: lote.id)
                                   .order(:id).last&.diferenca.to_d)
    puts

    if suspeitas.any?
      puts "As notas em que título e venda discordam:"

      suspeitas.each do |nota, lista, todas, orfas, fracao, aplicado, delta|
        puts format("  NF %-10s nota R$ %.2f · fração %.4f · título aplicado R$ %.2f · delta R$ %.2f",
                    nota.number, nota.total_amount.to_d, fracao, aplicado, delta)

        puts format("      recebíveis ligados a esta nota: %d, dos quais %d em algum repasse",
                    todas.size, todas.size - orfas.size)

        fiscal = nota.metadata.to_h["fiscal"].to_h

        puts format("      nota: produtos R$ %s · frete R$ %s · desconto R$ %s · outras R$ %s",
                    fiscal["valor_produtos"] || "—", fiscal["valor_frete"] || "—",
                    fiscal["valor_desconto"] || "—", fiscal["valor_outras"] || "—")

        lista.each do |u|
          linha = linhas[u.external_id].to_h

          puts format("      venda %-22s bruto R$ %9.2f · parcelamento R$ %7.2f · cupom R$ %7.2f · frete R$ %s",
                      u.external_id.to_s.truncate(22), u.gross_amount.to_d,
                      linha["FINANCING_FEE_AMOUNT"].to_d.abs, linha["COUPON_AMOUNT"].to_d.abs,
                      linha["SHIPPING_FEE_AMOUNT"] || linha["SHIPPING_AMOUNT"] || "—")
        end

        puts
      end
    end

    puts "Como ler:"
    puts "  fração < 1 com venda sem repasse -> o denominador conta venda que"
    puts "     nenhum repasse pagou; a fração fica pequena e o título entra por menos."
    puts "  título MAIOR que a venda -> a nota documenta algo que o bruto do"
    puts "     relatório não traz. `valor_frete` na nota é o primeiro suspeito."
    puts
    puts "Nada foi gravado."
  end
end
