namespace :conciliacao do
  desc "As vendas sem nota dos repasses são de ANTES de termos notas? (SOMENTE LEITURA)"
  task idade_das_vendas_sem_nota: :environment do
    # Reingerir julho trouxe 9 repasses e R$ 150 mil de diferença nova, quase toda
    # como "venda sem nota fiscal". Duas explicações opostas cabem no mesmo fato:
    #
    #   1. são vendas de JUNHO, liberadas em julho — o Tiny começou em 1º/07 e
    #      nunca tivemos nota delas. A diferença é história pré-integração, e o
    #      conserto é importar junho do Tiny.
    #   2. são vendas de JULHO cuja nota existe aqui e não foi ligada. Aí o
    #      conserto é o religamento, e a diferença é defeito nosso.
    #
    # A data do PEDIDO separa as duas, comparada com a data da nota mais antiga
    # que temos. Sem isso eu ia importar junho por palpite — e importar um mês
    # inteiro de notas fiscais por palpite é caro de desfazer.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    primeira_nota = Invoice.where(tenant_id: tenant.id).where.not(issued_at: nil).minimum(:issued_at)&.to_date

    puts "A nota mais antiga que temos é de #{primeira_nota || '(nenhuma)'}."
    puts

    lotes = PayoutBatch.where(tenant_id: tenant.id).order(paid_at: :desc)

    puts format("  %-6s %-12s %7s %12s %12s %14s",
                "id", "pago em", "s/ nota", "venda + velha", "venda + nova", "valor s/ nota")

    antes = { notas: 0, valor: BigDecimal("0") }
    depois = { notas: 0, valor: BigDecimal("0") }
    sem_data = 0

    lotes.each do |lote|
      orfas = lote
                .financial_entry_allocations
                .filter_map(&:receivable_unit)
                .uniq
                .select { |unidade| unidade.invoice_id.blank? }

      next if orfas.none?

      # A data da VENDA, não a do recebível: o recebível nasce quando o dinheiro
      # é liberado, semanas depois, e usá-lo aqui responderia outra pergunta.
      datas = orfas.filter_map { |unidade| unidade.order&.created_at&.to_date }

      orfas.each do |unidade|
        data = unidade.order&.created_at&.to_date

        if data.nil?
          sem_data += 1
        elsif primeira_nota && data < primeira_nota
          antes[:notas] += 1
          antes[:valor] += unidade.gross_amount.to_d
        else
          depois[:notas] += 1
          depois[:valor] += unidade.gross_amount.to_d
        end
      end

      puts format("  #%-5d %-12s %7d %12s %12s %14.2f",
                  lote.id, lote.paid_at&.to_date, orfas.size,
                  datas.min || "—", datas.max || "—",
                  orfas.sum(BigDecimal("0")) { |u| u.gross_amount.to_d })
    end

    puts
    puts "Vendas sem nota, pela data da VENDA:"
    puts format("  ANTES da nossa primeira nota:  %5d · R$ %11.2f  <- história pré-integração",
                antes[:notas], antes[:valor])
    puts format("  DEPOIS dela:                   %5d · R$ %11.2f  <- estas deveriam ter nota",
                depois[:notas], depois[:valor])
    puts format("  sem data de pedido:            %5d", sem_data) if sem_data.positive?
    puts

    puts "Como ler:"
    puts "  se quase tudo cair em ANTES, a diferença nova é história: o dinheiro de"
    puts "     julho pagou vendas de junho, e nunca tivemos nota de junho. Importar"
    puts "     junho do Tiny fecha — e enviar esses títulos ao OMIE é OUTRA decisão,"
    puts "     porque o cliente pode já tê-los lançado por outro caminho."
    puts "  se cair em DEPOIS, a nota existe aqui e o elo é que falta: conserto"
    puts "     nosso, no religamento, e não se importa nada."
    puts
    puts "Nada foi gravado."
  end
end
