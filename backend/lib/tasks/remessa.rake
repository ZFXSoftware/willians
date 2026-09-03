namespace :conciliacao do
  desc "Abre uma remessa e mostra venda a venda de onde vem a diferença (SOMENTE LEITURA)"
  task remessa: :environment do
    # A pergunta que esta tarefa responde: quando um repasse aparece com
    # divergência grande, é porque as vendas erradas foram penduradas nele, ou
    # porque os dois lados da comparação medem coisas diferentes?
    #
    # São causas opostas. A primeira se conserta agrupando certo; a segunda,
    # comparando a mesma grandeza. Sem abrir venda a venda, as duas produzem o
    # mesmo sintoma — uma diferença grande e sem explicação na tela.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    quantos = (ENV["QUANTOS"] || 3).to_i

    registros =
      if ENV["REPASSE"].present?
        ConciliacaoRegistro.where(tenant_id: tenant.id, payout_batch_id: ENV["REPASSE"])
      else
        ConciliacaoRegistro
          .where(tenant_id: tenant.id, status: "divergent")
          .where.not(payout_batch_id: nil)
          .order(Arel.sql("ABS(COALESCE(diferenca, 0)) DESC"))
          .limit(quantos)
      end

    if registros.none?
      puts "Nenhum repasse divergente. Rode a conciliação antes, ou use REPASSE=<id>."

      next
    end

    registros.each do |registro|
      lote = PayoutBatch.find_by(id: registro.payout_batch_id)

      next if lote.blank?

      imprimir_remessa(tenant, lote, registro)
    end

    puts "Como ler:"
    puts "  diferença ≈ soma dos fretes/ajustes das vendas -> os dois lados medem"
    puts "     grandezas diferentes (valor da venda no marketplace x valor da NF)."
    puts "  vendas com data muito anterior ao repasse       -> agrupamento errado:"
    puts "     o repasse recolheu recebível que ele não pagou."
    puts
    puts "Nada foi gravado."
  end

  def imprimir_remessa(tenant, lote, registro)
    extrato = lote.financial_entry

    puts "=" * 78
    puts "Repasse ##{lote.id} · ref #{lote.external_id} · pago em #{lote.paid_at}"
    puts
    puts format("  dinheiro que entrou (extrato):  R$ %.2f", extrato&.amount.to_d)
    puts format("  lote: bruto R$ %.2f · taxa R$ %.2f · líquido R$ %.2f",
                lote.gross_amount.to_d, lote.fee_amount.to_d, lote.net_amount.to_d)
    puts format("  conciliação: nosso R$ %.2f · OMIE %s · diferença R$ %.2f",
                registro.valor.to_d,
                registro.conciliation_metadata&.dig("valor_omie") || "—",
                registro.diferenca.to_d)
    puts

    unidades = lote
                 .financial_entry_allocations
                 .filter_map(&:receivable_unit)
                 .uniq

    puts "  #{unidades.size} venda(s) penduradas nesta remessa:"
    puts

    puts format("    %-24s %-12s %12s %-10s %12s", "pedido", "liberado em", "venda (ML)", "NF", "valor NF")

    soma_ml = BigDecimal("0")
    soma_nf = BigDecimal("0")

    unidades.sort_by { |u| u.expected_on || Date.new(1970) }.first(40).each do |unidade|
      nota = unidade.invoice

      soma_ml += unidade.gross_amount.to_d
      soma_nf += nota&.total_amount.to_d

      puts format("    %-24s %-12s %12.2f %-10s %12.2f",
                  unidade.order&.external_id.to_s[0, 24],
                  unidade.expected_on,
                  unidade.gross_amount.to_d,
                  nota&.number || "sem NF",
                  nota&.total_amount.to_d)
    end

    puts "    ... (#{unidades.size - 40} outras)" if unidades.size > 40
    puts

    # A decomposição que separa as duas causas.
    puts format("  soma das vendas no marketplace: R$ %.2f", soma_ml)
    puts format("  soma das notas fiscais:         R$ %.2f", soma_nf)
    puts format("  diferença entre as duas:        R$ %.2f", soma_ml - soma_nf)
    puts

    datas = unidades.filter_map(&:expected_on)

    if datas.any?
      puts format("  vendas liberadas entre %s e %s (repasse em %s)",
                  datas.min, datas.max, lote.paid_at.to_date)

      antigas = datas.count { |data| data < lote.paid_at.to_date - 30 }

      puts "  #{antigas} venda(s) liberadas há mais de 30 dias do repasse" if antigas.positive?
    end

    puts
  end
end
