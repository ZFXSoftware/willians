require "test_helper"

module Marketplace
  # O último elo da corrente.
  #
  # O relatório de liberações do Mercado Livre identifica cada linha pelo id do
  # PAGAMENTO — a coluna do pedido vem vazia em todas. As notas do Tiny trazem
  # o número do PEDIDO. Sem ninguém ligando um ao outro, o dinheiro e a nota
  # fiscal nunca se encontram, e a conciliação contra o OMIE fica sem chave.
  class VinculoDePedidosTest < ActiveSupport::TestCase
    def setup
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant, plataforma: "mercado_livre", external_id: "SELLER-1")
    end

    def lancamento(tipo:, direcao:, pagamento:, sufixo:, valor: 100)
      FinancialEntry.create!(
        tenant: @tenant, platform_account: @conta,
        external_id: "MLREL-#{pagamento}-#{sufixo}", source: :mercado_livre,
        entry_type: tipo, direction: direcao, amount: valor,
        occurred_at: 2.days.ago, available_on: 2.days.ago.to_date,
        status: :settled, metadata: { "source_id" => pagamento }
      )
    end

    # Devolve os pedidos que o Mercado Livre devolveria, sem sair para a rede.
    def cliente_falso(pedidos)
      Object.new.tap do |o|
        o.define_singleton_method(:orders) { |**| pedidos }
      end
    end

    def vincular(pedidos)
      VinculoDePedidos.new(
        tenant: @tenant, platform_account: @conta,
        start_date: Date.current - 30, end_date: Date.current,
        client: cliente_falso(pedidos)
      ).call
    end

    def pedido_ml(id: "2000017100877708", pagamentos: [ "PAY-1" ], comprador: "fulano")
      { external_id: id, pagamentos: pagamentos, status: "paid",
        total: 150.0, criado_em: 2.days.ago.iso8601, comprador: comprador }
    end

    test "liga o lançamento ao pedido pelo id do pagamento" do
      venda = lancamento(tipo: :sale, direcao: :credit, pagamento: "PAY-1", sufixo: "SALE")

      resumo = vincular([ pedido_ml ])

      assert_equal 1, resumo[:pedidos]
      assert_equal 1, resumo[:lancamentos_ligados]

      assert_equal "2000017100877708", venda.reload.order.external_id
    end

    # Venda e taxas saem da MESMA linha do extrato e compartilham o SOURCE_ID.
    test "as taxas da venda vão junto, porque compartilham o pagamento" do
      lancamento(tipo: :sale, direcao: :credit, pagamento: "PAY-1", sufixo: "SALE")
      taxa = lancamento(tipo: :fee, direcao: :debit, pagamento: "PAY-1", sufixo: "FEE", valor: 15)

      vincular([ pedido_ml ])

      assert_not_nil taxa.reload.order_id
    end

    # É por `order_id` que o InvoiceSync pendura a nota fiscal. O recebível
    # nasce antes deste vínculo existir, então ficaria para trás — e é ELE que
    # o repasse liquida e a conciliação compara.
    test "o recebível da venda também recebe o pedido" do
      lancamento(tipo: :sale, direcao: :credit, pagamento: "PAY-1", sufixo: "SALE")

      recebivel = ReceivableUnit.find_by(tenant: @tenant)

      assert_nil recebivel.order_id, "nasce sem pedido: o extrato não traz"

      vincular([ pedido_ml ])

      assert_equal "2000017100877708", recebivel.reload.order.external_id
    end

    test "um pedido com dois pagamentos liga os dois" do
      lancamento(tipo: :sale, direcao: :credit, pagamento: "PAY-1", sufixo: "SALE")
      lancamento(tipo: :sale, direcao: :credit, pagamento: "PAY-2", sufixo: "SALE")

      resumo = vincular([ pedido_ml(pagamentos: [ "PAY-1", "PAY-2" ]) ])

      assert_equal 2, resumo[:lancamentos_ligados]
    end

    # O pedido pode já existir vindo da nota do Tiny, que o cria só com o
    # número. Aqui ele ganha conteúdo.
    test "pedido criado pela nota do Tiny ganha comprador e valor" do
      magro = criar_pedido(tenant: @tenant, conta: @conta, external_id: "2000017100877708")

      magro.update!(metadata: { "origem" => "tiny_invoice_sync" })

      lancamento(tipo: :sale, direcao: :credit, pagamento: "PAY-1", sufixo: "SALE")

      vincular([ pedido_ml(comprador: "sirley") ])

      magro.reload

      assert_equal "sirley", magro.buyer_name
      assert_equal BigDecimal("150"), magro.total_amount
      assert_equal 1, Order.where(tenant: @tenant).count, "não pode nascer um segundo pedido"
    end

    test "lançamento já ligado a outro pedido não é sobrescrito" do
      outro = criar_pedido(tenant: @tenant, conta: @conta, external_id: "OUTRO")

      venda = lancamento(tipo: :sale, direcao: :credit, pagamento: "PAY-1", sufixo: "SALE")
      venda.update!(order: outro)

      vincular([ pedido_ml ])

      assert_equal outro.id, venda.reload.order_id, "vínculo existente é informação, não sujeira"
    end

    # O 403 "caller.id does not match buyer or seller" da produção: a conta
    # tinha o id de um vendedor e a credencial o token de outro. Perguntar pelos
    # pedidos de um usando o token do outro é recusa garantida — e o id da
    # credencial veio junto com o token, então é impossível ele divergir.
    test "consulta pelo dono do token, não pelo id gravado na conta" do
      MarketplaceCredential.create!(
        tenant: @tenant, platform_account: @conta, platform: "mercado_livre",
        status: :connected, access_token: "AT", external_user_id: "999888777",
        expires_at: 4.hours.from_now
      )

      provider = Providers::MercadoLivreProvider.new(account: @conta)

      assert_equal "999888777", provider.send(:vendedor)
      assert_equal "SELLER-1", @conta.external_id, "o cadastro continua como está"
    end

    test "sem credencial, cai no id da conta" do
      provider = Providers::MercadoLivreProvider.new(account: @conta)

      assert_equal "SELLER-1", provider.send(:vendedor)
    end

    # O extrato é datado pela LIBERAÇÃO e os pedidos pela VENDA, e o Mercado
    # Pago segura o dinheiro por semanas. Pedindo a mesma janela para os dois,
    # a liberação de hoje de uma venda antiga não acha o pedido dela — foi o
    # que deixou 897 lançamentos órfãos na primeira carga com dado real.
    test "os pedidos são buscados numa janela maior que a do extrato" do
      pedido_de = nil

      cliente = Object.new

      cliente.define_singleton_method(:orders) do |start_date:, end_date:|
        pedido_de = start_date

        []
      end

      VinculoDePedidos.new(
        tenant: @tenant, platform_account: @conta,
        start_date: Date.current - 30, end_date: Date.current,
        client: cliente
      ).call

      assert_operator pedido_de, :<, Date.current - 30,
                      "a janela dos pedidos precisa alcançar vendas anteriores ao extrato"
    end

    test "pedido sem pagamento nenhum é ignorado" do
      resumo = vincular([ pedido_ml(pagamentos: []) ])

      assert_equal 0, resumo[:lancamentos_ligados]
      assert_equal 0, Order.where(tenant: @tenant).count
    end
  end
end
