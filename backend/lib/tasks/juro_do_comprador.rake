namespace :conciliacao do
  desc "A sobra sem hipótese é juro do comprador? Pergunta ao pedido no ML (SOMENTE LEITURA)"
  task juro_do_comprador: :environment do
    # A maior causa que ainda não tem nome: 169 notas em que `bruto > produtos` e nem o
    # frete nem o parcelamento explicam — R$ 2.804,31.
    #
    # A hipótese é que `GROSS_AMOUNT` não é o que o vendedor vendeu, e sim o que o
    # COMPRADOR pagou: mercadoria + juro do parcelamento escolhido por ele (+ cupom
    # subsidiado pelo marketplace). A nota documenta a mercadoria, então a sobra seria
    # dinheiro que nunca foi receita do vendedor.
    #
    # Quem sabe o que o comprador pagou é o PEDIDO, e ele é fonte independente da nota:
    # decidir pela nota seria circular, e a diferença fecharia por construção.
    #
    # Isto NÃO grava nada. É a medição que decide se vale capturar o campo na ingestão.
    #
    # Eu já tinha conferido `transaction_amount == valor_produtos` em 10 pedidos, mas não
    # sei de qual balde aqueles dez vieram. Amostra tirada de outro lugar não responde
    # sobre este — é o mesmo erro de método que já me custou quatro diagnósticos aqui.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    limite = (ENV["LIMITE"].presence || 40).to_i

    conta = PlatformAccount.find_by(tenant_id: tenant.id, platform: "mercado_livre", status: "active")

    abort "Nenhuma conta ativa do Mercado Livre." if conta.blank?

    client = Marketplace::MercadoLivre::OrdersClient.new(
      access_token: Marketplace::Credentials::TokenProvider.new(platform_account: conta).access_token,
      seller_id: conta.external_id
    )

    lotes = PayoutBatch.where(tenant_id: tenant.id).order(:paid_at).to_a

    # Junta os casos do balde `sobra_sem_hipotese`, com a composição que o MOTOR
    # calculou — e não uma conta refeita aqui, que mediria a minha suposição.
    casos = []

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
        bruto_total = totais[nota.id].to_d

        bruto_aqui = vendas.sum(BigDecimal("0")) { |u| u.gross_amount.to_d }

        fracao = bruto_total.positive? ? (bruto_aqui / bruto_total) : BigDecimal("1")

        composicao = Conciliacao::ComposicaoDaVenda.para(
          nota: nota, vendas: vendas, linhas: linhas, fracao: fracao
        )

        next unless composicao.hipotese == :sobra_sem_hipotese

        # Um pedido por venda: o `transaction_amount` é do pagamento do pedido, e
        # rateá-lo por nota de pacote traria a fração de volta para dentro da medição.
        # Nota dividida entre repasses fica de fora — ali a comparação é 1:1 apenas
        # quando a fração é inteira.
        next unless fracao == 1 && vendas.size == 1

        pedido = vendas.first.order

        next if pedido.blank?

        casos << [ nota, vendas.first, pedido, composicao ]
      end
    end

    puts format("Notas com sobra sem hipótese, um pedido só e sem rateio: %d", casos.size)
    puts format("Perguntando ao Mercado Livre os %d primeiros...", [ casos.size, limite ].min)
    puts

    achados = Hash.new(0)
    valores = Hash.new { |h, k| h[k] = BigDecimal("0") }
    exemplos = Hash.new { |h, k| h[k] = [] }

    tolerancia = BigDecimal("0.10")

    casos.first(limite).each do |nota, venda, pedido, composicao|
      dados = client.order_raw(pedido.external_id)

      if dados.blank?
        achados["pedido não respondeu"] += 1

        next
      end

      pagamentos = Array(dados["payments"])

      # `transaction_amount` é o valor da transação SEM o juro; `total_paid_amount` é o
      # que o comprador desembolsou. A diferença entre os dois é o juro que ele aceitou.
      transacao = pagamentos.sum(BigDecimal("0")) { |p| p["transaction_amount"].to_d }

      pago = pagamentos.sum(BigDecimal("0")) { |p| p["total_paid_amount"].to_d }

      cupom = pagamentos.sum(BigDecimal("0")) { |p| p["coupon_amount"].to_d }

      frete_pedido = dados.dig("shipping", "cost").to_d

      sobra = composicao.sobra

      # Candidatos de fonte independente contra a sobra medida.
      candidatos = {
        "bruto − transaction_amount" => composicao.bruto - transacao,
        "total_paid − transaction_amount (juro)" => pago - transacao,
        "cupom do pedido" => cupom,
        "frete do pedido" => frete_pedido,
        "bruto − total_amount do pedido" => composicao.bruto - dados["total_amount"].to_d
      }

      nome = candidatos.find { |_, v| v.positive? && (sobra - v).abs <= tolerancia }&.first || "nada explica"

      achados[nome] += 1
      valores[nome] += sobra

      if exemplos[nome].size < 4
        exemplos[nome] << format(
          "NF %-8s pedido %-18s sobra %7.2f · bruto %8.2f · produtos %8.2f · transacao %8.2f · pago %8.2f · total %8.2f · parc %6.2f",
          nota.number, pedido.external_id, sobra, composicao.bruto, composicao.produtos,
          transacao, pago, dados["total_amount"].to_d, composicao.parcelamento
        )
      end

      sleep 0.25
    rescue StandardError => e
      achados["erro: #{e.class}"] += 1
    end

    puts "O que a sobra é:"
    achados.sort_by { |_, q| -q }.each do |nome, quantas|
      puts format("  %-42s %4d caso(s) · R$ %8.2f", nome, quantas, valores[nome])

      exemplos[nome].each { |linha| puts "      #{linha}" }
    end

    puts
    puts "Como ler:"
    puts "  `bruto − transaction_amount` explicando a maioria -> o bruto do relatório é o"
    puts "     que o COMPRADOR pagou, e o valor da venda é o transaction_amount. Vale"
    puts "     capturar o campo na ingestão e usá-lo como o valor da venda."
    puts "  `nada explica` dominando -> o pedido também não sabe, e a pergunta é para o"
    puts "     Mercado Livre."
    puts
    puts "Nada foi gravado."
  end
end
