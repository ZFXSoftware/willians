namespace :conciliacao do
  desc "Todas as linhas de dinheiro de um pedido, do nosso banco (SOMENTE LEITURA)"
  task composicao_da_venda: :environment do
    # O Mercado Livre nos credita MAIS que o valor do pedido: R$ 222,66 num
    # pedido de R$ 194,65. Não é desconto — é dinheiro a mais, e a hipótese é
    # frete pago pelo comprador e repassado ao vendedor.
    #
    # Isso se confere no nosso próprio banco: o `gross_amount` veio do relatório
    # de liberações, e se o frete é uma linha separada lá, ela está aqui. Uma
    # pergunta que a nossa base responde não precisa virar chamada de API.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    externo = ENV["PEDIDO"].to_s.strip

    abort "Diga qual pedido com PEDIDO=<id do marketplace>." if externo.blank?

    pedido = Order.find_by(tenant_id: tenant.id, external_id: externo)

    abort "Pedido #{externo} não está no nosso banco." if pedido.blank?

    unidades = ReceivableUnit.where(tenant_id: tenant.id, order_id: pedido.id).order(:id)

    puts "Pedido #{externo}"
    puts

    puts "Vendas (receivable_units) — é daqui que sai o valor comparado:"

    unidades.each do |unidade|
      puts format("  #%-6d bruto %10.2f · taxa %8.2f · líquido %10.2f · %s · %s",
                  unidade.id, unidade.gross_amount.to_d, unidade.fee_amount.to_d,
                  unidade.net_amount.to_d, unidade.status, unidade.expected_on)

      puts "      external_id: #{unidade.external_id}"

      puts "      metadata:    #{unidade.metadata.to_h.except('raw').inspect.truncate(300)}" if unidade.metadata.present?

      nota = unidade.invoice

      puts format("      nota ligada: %s R$ %.2f", nota.number, nota.total_amount.to_d) if nota
    end

    puts
    puts format("  soma dos brutos: R$ %.2f", unidades.sum(BigDecimal("0")) { |u| u.gross_amount.to_d })
    puts

    lancamentos = FinancialEntry.where(tenant_id: tenant.id, order_id: pedido.id).order(:occurred_at, :id)

    puts "Lançamentos (financial_entries) — cada linha do relatório de liberações:"

    if lancamentos.none?
      puts "  (nenhum)"
    end

    lancamentos.each do |lancamento|
      puts format("  %-12s %-8s bruto %10.2f · taxa %8.2f · líquido %10.2f",
                  lancamento.entry_type, lancamento.direction, lancamento.amount.to_d,
                  lancamento.fee_amount.to_d, lancamento.net_amount.to_d)

      puts format("      record_type: %s · external_id: %s",
                  lancamento.metadata["record_type"], lancamento.external_id.to_s.truncate(60))

      # O relatório de liberações tem coluna própria para cada tipo de valor, e
      # o frete seria uma delas. Guardamos a linha inteira em `raw_payload`, e
      # é a única fonte que pode nomear os R$ 28,01 sem chamar API.
      cru = lancamento.raw_payload

      cru = JSON.parse(cru) rescue {} if cru.is_a?(String)

      cru = cru.to_h

      interessantes = cru.select do |chave, valor|
        chave.to_s.match?(/SHIP|FREIGHT|FRETE|COUPON|DISCOUNT|FEE|AMOUNT/i) && valor.to_s.strip.present?
      end

      puts "      #{interessantes.inspect.truncate(400)}" if interessantes.any?
    end

    puts
    puts format("  soma dos lançamentos: R$ %.2f",
                lancamentos.sum(BigDecimal("0")) { |l| l.direction.to_s == "debit" ? -l.amount.to_d : l.amount.to_d })
    puts

    # TODAS as linhas do mesmo pagamento, e não só as ligadas ao pedido.
    #
    # O relatório identifica cada linha pelo SOURCE_ID (o pagamento no Mercado
    # Pago) e, segundo o próprio log da importação, NENHUMA linha traz o número
    # do pedido. Filtrar por pedido mostra a venda e esconde as deduções — e as
    # deduções são justamente o que falta explicar: a linha da venda diz
    # NET_CREDIT_AMOUNT 145,75 sobre um bruto de 222,66 menos taxa de 27,25,
    # que daria 195,41.
    fontes = unidades.filter_map { |u| u.external_id.to_s[/MLREL-(\d+)-/, 1] }.uniq

    fontes.each do |fonte|
      irmas = FinancialEntry.where(tenant_id: tenant.id)
                            .where("external_id LIKE ?", "MLREL-#{fonte}-%")
                            .order(:id)

      puts "Todas as linhas do pagamento #{fonte} (#{irmas.count}):"

      irmas.each do |irma|
        puts format("  %-12s %-8s %10.2f  %s",
                    irma.entry_type, irma.direction, irma.amount.to_d, irma.external_id)

        bruto_linha = irma.raw_payload

        bruto_linha = (JSON.parse(bruto_linha) rescue {}) if bruto_linha.is_a?(String)

        # A linha INTEIRA, sem filtro meu. Escolher quais colunas mostrar já me
        # fez esconder a resposta uma vez neste mesmo relatório.
        puts "      #{bruto_linha.to_h.inspect}" if bruto_linha.present?
      end

      puts
    end

    puts "Como ler: se existe linha SEPARADA de frete, o valor comparado precisa"
    puts "excluí-la — a nota fiscal documenta a mercadoria, não o transporte."
    puts
    puts "Nada foi gravado."
  end
end
