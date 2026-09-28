namespace :conciliacao do
  desc "As notas cujo delta não tem causa nomeada: o que elas têm em comum (SOMENTE LEITURA)"
  task delta_sem_causa: :environment do
    # Depois do valor do pedido entrar na base, o pente fino acusa 39 notas em 4 repasses
    # com "delta sem causa nomeada" — R$ 230,32, e é a maior causa que sobrou.
    #
    # "Sem causa nomeada" é o balde do que não caiu em nenhum outro: nem sobra sem
    # hipótese, nem rateio de pacote, nem título duplicado, nem nota sem valor. Então a
    # pergunta é o que ESSAS notas têm em comum.
    #
    # Em vez de adivinhar, cada nota é descrita pelas suas dimensões medidas e o delta é
    # agrupado por elas. Padrão que aparece em quase todas vira hipótese; padrão que
    # aparece em metade não explica nada.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    lotes = PayoutBatch.where(tenant_id: tenant.id).order(:paid_at).to_a

    puts "Lendo os títulos do OMIE uma vez..."

    leitor = Omie::Readers::ReceivableTotals.new(client: Omie::Client.new(tenant: tenant))

    titulos = Current.with_tenant(tenant) do
      leitor.call(start_date: lotes.first.paid_at.to_date - 120, end_date: Date.current)
    end

    puts

    achados = []

    lotes.each do |lote|
      unidades = lote.financial_entry_allocations
                     .filter_map(&:receivable_unit)
                     .uniq
                     .reject(&:nao_e_venda?)

      por_nota = unidades.select(&:invoice).group_by(&:invoice)

      next if por_nota.empty?

      linhas = FinancialEntry
                 .where(tenant_id: tenant.id, external_id: unidades.map(&:external_id))
                 .pluck(:external_id, :raw_payload)
                 .to_h { |externo, cru| [ externo, cru.is_a?(Hash) ? cru : {} ] }

      totais = ReceivableUnit
                 .where(tenant_id: tenant.id, invoice_id: por_nota.keys.map(&:id))
                 .group(:invoice_id)
                 .sum(:gross_amount)

      por_nota.each do |nota, vendas|
        chave = Omie::Readers::ReceivableTotals.normalizar(nota.number)

        titulo = titulos[chave]

        next if titulo.blank?

        bruto_total = totais[nota.id].to_d

        bruto_aqui = vendas.sum(BigDecimal("0")) { |u| u.gross_amount.to_d }

        fracao = bruto_total.positive? ? (bruto_aqui / bruto_total) : BigDecimal("1")

        composicao = Conciliacao::ComposicaoDaVenda.para(
          nota: nota, vendas: vendas, linhas: linhas, fracao: fracao
        )

        delta = composicao.delta_para(titulo, fracao)

        next if delta.abs <= BigDecimal("0.01")

        # Só o balde de que esta tarefa fala: os outros já têm nome.
        next if composicao.produtos.zero?
        next if composicao.hipotese == :sobra_sem_hipotese
        next if (titulo - (nota.total_amount.to_d * 2)).abs <= BigDecimal("0.02")
        next if fracao < 1

        achados << {
          lote: lote.id, nota: nota, delta: delta, composicao: composicao,
          titulo: titulo, vendas: vendas.size,
          origem: nota.metadata.to_h["origem"].to_s
        }
      end
    end

    if achados.empty?
      puts "Nenhuma nota com delta sem causa nomeada."

      next
    end

    puts format("Notas com delta sem causa nomeada: %d · soma |delta| R$ %.2f · em %d repasse(s)",
                achados.size, achados.sum { |a| a[:delta].abs }, achados.map { |a| a[:lote] }.uniq.size)
    puts

    # DIMENSÃO 1: o título do OMIE bate com o valor da nota?
    #
    # Se não bate, o problema está no título — envio errado, título editado à mão, outro
    # documento com o mesmo número — e não na composição da venda.
    titulo_difere = achados.select { |a| (a[:titulo] - a[:nota].total_amount.to_d).abs > BigDecimal("0.01") }

    puts format("Título do OMIE diferente do valor da nota: %d de %d · soma |delta| R$ %.2f",
                titulo_difere.size, achados.size, titulo_difere.sum { |a| a[:delta].abs })

    titulo_difere.first(8).each do |a|
      puts format("    NF %-8s titulo %9.2f · nota %9.2f · dif %8.2f · delta %8.2f",
                  a[:nota].number, a[:titulo], a[:nota].total_amount.to_d,
                  a[:titulo] - a[:nota].total_amount.to_d, a[:delta])
    end

    puts

    # DIMENSÃO 2: a nota fecha com a soma das suas partes?
    #
    # `produtos + frete − desconto == total`. Quando não fecha, o que falta é uma coluna
    # fiscal que não estamos lendo (outras despesas, seguro, IPI).
    nota_nao_fecha = achados.reject do |a|
      c = a[:composicao]

      (c.produtos + c.frete - c.desconto - a[:nota].total_amount.to_d).abs <= BigDecimal("0.01")
    end

    puts format("Nota cujo total != produtos + frete − desconto: %d de %d · soma |delta| R$ %.2f",
                nota_nao_fecha.size, achados.size, nota_nao_fecha.sum { |a| a[:delta].abs })

    nota_nao_fecha.first(8).each do |a|
      c = a[:composicao]

      fiscal = a[:nota].metadata.to_h["fiscal"].to_h

      puts format("    NF %-8s total %9.2f · prod %9.2f · frete %7.2f · desc %7.2f · falta %8.2f · outras %s seguro %s ipi %s",
                  a[:nota].number, a[:nota].total_amount.to_d, c.produtos, c.frete, c.desconto,
                  a[:nota].total_amount.to_d - (c.produtos + c.frete - c.desconto),
                  fiscal["valor_outras"].inspect, fiscal["valor_seguro"].inspect, fiscal["valor_ipi"].inspect)
    end

    puts

    # DIMENSÃO 3: o sinal, e a origem da nota.
    puts format("Delta POSITIVO (marketplace pagou mais): %d · R$ %.2f",
                achados.count { |a| a[:delta].positive? },
                achados.select { |a| a[:delta].positive? }.sum { |a| a[:delta] })
    puts format("Delta NEGATIVO (OMIE espera mais):       %d · R$ %.2f",
                achados.count { |a| a[:delta].negative? },
                achados.select { |a| a[:delta].negative? }.sum { |a| a[:delta] })
    puts

    puts "Por origem da nota:"
    achados.group_by { |a| a[:origem].presence || "—" }.each do |origem, lista|
      puts format("  %-22s %4d · R$ %8.2f", origem, lista.size, lista.sum { |a| a[:delta].abs })
    end

    puts
    puts "Por repasse:"
    achados.group_by { |a| a[:lote] }.sort.each do |lote, lista|
      puts format("  #%-5d %4d nota(s) · R$ %8.2f", lote, lista.size, lista.sum { |a| a[:delta].abs })
    end

    puts
    puts "Os dez maiores, com tudo:"
    achados.sort_by { |a| -a[:delta].abs }.first(10).each do |a|
      c = a[:composicao]

      puts format("  NF %-8s lote #%-4d delta %8.2f · bruto %9.2f · prod %9.2f · titulo %9.2f · nota %9.2f · hip %s · vendas %d",
                  a[:nota].number, a[:lote], a[:delta], c.bruto, c.produtos, a[:titulo],
                  a[:nota].total_amount.to_d, c.hipotese, a[:vendas])
    end

    puts
    puts "Nada foi gravado."
  end
end
