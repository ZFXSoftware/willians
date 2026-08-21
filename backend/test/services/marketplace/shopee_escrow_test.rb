require "test_helper"

module Marketplace
  # A documentação da Shopee publica a FÓRMULA do escrow_amount. Transcrevê-la
  # dá um teste que nenhuma outra integração tem: a decomposição em venda e
  # taxas pode se conferir contra o líquido que a própria Shopee informou.
  class ShopeeEscrowTest < ActiveSupport::TestCase
    S = Marketplace::Shopee

    DE = Date.new(2026, 8, 1)

    ATE = Date.new(2026, 8, 7)

    LIBERADO = Time.zone.at(1_651_849_648)

    # Pedido coerente: os campos somam exatamente o escrow_amount.
    #
    #   venda 200,00
    #   - comissão 20,00 - serviço 5,00 - frete 12,00 - processamento 3,00
    #   + frete pago pelo comprador 10,00
    #   = 170,00
    def self.pedido_coerente
      {
        "response" => {
          "order_sn" => "220415N6SB140P",
          "order_income" => {
            "escrow_amount" => 170.0,
            "original_cost_of_goods_sold" => 200.0,
            "commission_fee" => 20.0,
            "service_fee" => 5.0,
            "actual_shipping_fee" => 12.0,
            "seller_order_processing_fee" => 3.0,
            "buyer_paid_shipping_fee" => 10.0,
            "aff_currency" => "BRL"
          }
        }
      }
    end

    def eventos(payload = self.class.pedido_coerente)
      leitor = S::EscrowEvents.new(payload, liberado_em: LIBERADO)

      [leitor.call, leitor]
    end

    # ------------------------------------------------------- decomposição

    test "a venda entra pelo bruto e cada taxa vira um lançamento" do
      lista, = eventos
      por_id = lista.index_by { |e| e[:external_id] }

      venda = por_id.fetch("SHOPEE-220415N6SB140P-ORIGINAL_COST_OF_GOODS_SOLD")

      assert_equal :sale, venda[:entry_type]
      assert_equal :credit, venda[:direction]
      assert_equal BigDecimal("200.0"), venda[:amount]
      assert_equal "220415N6SB140P", venda[:external_order_id], "o elo com o pedido"

      comissao = por_id.fetch("SHOPEE-220415N6SB140P-COMMISSION_FEE")

      assert_equal :fee, comissao[:entry_type]
      assert_equal :debit, comissao[:direction]
      assert_equal BigDecimal("20.0"), comissao[:amount]
      assert_equal "Comissão", comissao[:description]
    end

    test "campo zerado não vira lançamento" do
      lista, = eventos

      assert lista.none? { |e| e[:amount].zero? }
      # O payload tem 6 campos preenchidos; o resto da fórmula está ausente.
      assert_equal 6, lista.size
    end

    test "a data de liberação vem da lista e é carimbada em tudo" do
      lista, = eventos

      assert lista.all? { |e| e[:occurred_at] == LIBERADO }
      assert lista.all? { |e| e[:available_on] == LIBERADO.to_date }
    end

    # -------------------------------------------------- a conferência

    test "a decomposição confere com o escrow_amount informado" do
      _, leitor = eventos

      assert_equal 0, leitor.diferenca
      assert leitor.confere?
    end

    test "mapeamento errado é detectado em vez de virar lançamento" do
      # Mesmo pedido, mas a Shopee diz que o líquido é outro.
      payload = self.class.pedido_coerente
      payload["response"]["order_income"]["escrow_amount"] = 150.0

      _, leitor = eventos(payload)

      refute leitor.confere?, "a diferença de 20,00 tem que ser vista"
      assert_equal BigDecimal("20.0"), leitor.diferenca
    end

    test "ajuste de pedido entra com data e motivo próprios" do
      payload = self.class.pedido_coerente
      renda = payload["response"]["order_income"]
      renda["order_adjustment"] = [
        { "amount" => -15.0, "date" => 1_688_107_565, "currency" => "BRL",
          "adjustment_reason" => "Return Refund deduction" }
      ]
      renda["escrow_amount_after_adjustment"] = 155.0

      lista, leitor = eventos(payload)

      ajuste = lista.find { |e| e[:external_id].end_with?("ADJ-0") }

      assert_equal :adjustment, ajuste[:entry_type]
      assert_equal :debit, ajuste[:direction]
      assert_equal BigDecimal("15.0"), ajuste[:amount]
      assert_equal "Return Refund deduction", ajuste[:description]
      assert_equal Time.zone.at(1_688_107_565), ajuste[:occurred_at]

      # Havendo ajuste, o alvo da conferência é o valor APÓS o ajuste.
      assert leitor.confere?, "diferença de #{leitor.diferenca}"
    end

    test "valor negativo num campo de dedução inverte a direção" do
      payload = self.class.pedido_coerente
      # Frete negativo é estorno de frete: dinheiro voltando.
      payload["response"]["order_income"]["actual_shipping_fee"] = -12.0
      payload["response"]["order_income"]["escrow_amount"] = 194.0

      lista, leitor = eventos(payload)

      frete = lista.find { |e| e[:external_id].end_with?("ACTUAL_SHIPPING_FEE") }

      assert_equal :credit, frete[:direction]
      assert_equal BigDecimal("12.0"), frete[:amount]
      assert leitor.confere?
    end

    test "resposta vazia não quebra" do
      lista, = eventos({ "response" => {} })

      assert_empty lista
    end

    # ----------------------------------------------------- lista e paginação

    class ClienteFalso
      attr_reader :chamadas

      def initialize(paginas:, detalhes: {})
        @paginas = paginas
        @detalhes = detalhes
        @chamadas = []
      end

      def get(chave, params = {})
        @chamadas << [chave, params]

        return @paginas[params[:page_no] - 1] if chave == :escrow_list

        @detalhes.fetch(params[:order_sn]) { raise S::Client::ApiError.new("order_not_found") }
      end
    end

    def pagina(itens, mais:)
      { "response" => { "more" => mais, "escrow_list" => itens } }
    end

    def item(sn) = { "order_sn" => sn, "payout_amount" => 170.0, "escrow_release_time" => 1_651_849_648 }

    test "segue a paginação por `more`, não por total de páginas" do
      cliente = ClienteFalso.new(
        paginas: [pagina([item("A")], mais: true), pagina([item("B")], mais: false)],
        detalhes: { "A" => self.class.pedido_coerente, "B" => self.class.pedido_coerente }
      )

      resultado = S::EscrowReader.new(client: cliente).call(start_date: DE, end_date: ATE)

      assert_equal 2, resultado.pedidos
      assert_equal [1, 2], cliente.chamadas.select { |c, _| c == :escrow_list }.map { |_, p| p[:page_no] }
    end

    test "o filtro é por data de liberação, em timestamp Unix" do
      cliente = ClienteFalso.new(paginas: [pagina([], mais: false)])

      S::EscrowReader.new(client: cliente).call(start_date: DE, end_date: ATE)

      params = cliente.chamadas.first.last

      assert_equal DE.beginning_of_day.to_i, params[:release_time_from]
      assert_equal ATE.end_of_day.to_i, params[:release_time_to]
      assert_equal 100, params[:page_size], "o máximo permitido, para poupar chamadas"
    end

    test "pedido que não fecha é descartado e reportado" do
      divergente = self.class.pedido_coerente
      divergente["response"]["order_sn"] = "B"
      divergente["response"]["order_income"]["escrow_amount"] = 999.0

      cliente = ClienteFalso.new(
        paginas: [pagina([item("A"), item("B")], mais: false)],
        detalhes: { "A" => self.class.pedido_coerente, "B" => divergente }
      )

      resultado = S::EscrowReader.new(client: cliente).call(start_date: DE, end_date: ATE)

      assert_equal 1, resultado.divergentes.size
      assert_equal "B", resultado.divergentes.first[:order_sn]
      # O ponto: nenhum lançamento do pedido divergente entra no razão.
      assert resultado.eventos.none? { |e| e[:external_order_id] == "B" }
      assert resultado.eventos.any? { |e| e[:external_order_id] == "220415N6SB140P" }
    end

    test "falha em um pedido não derruba o período" do
      cliente = ClienteFalso.new(
        paginas: [pagina([item("A"), item("SUMIU")], mais: false)],
        detalhes: { "A" => self.class.pedido_coerente }
      )

      resultado = S::EscrowReader.new(client: cliente).call(start_date: DE, end_date: ATE)

      assert_equal 1, resultado.falhas.size
      assert_equal "SUMIU", resultado.falhas.first[:order_sn]
      assert_operator resultado.eventos.size, :>, 0, "o pedido bom continua entrando"
    end

    # ------------------------------------------------------------ persistência

    test "os eventos da Shopee viram lançamentos e não duplicam" do
      tenant = criar_tenant
      conta = criar_conta(tenant: tenant, plataforma: "shopee")
      fixos, = eventos

      ingerir = lambda do
        Ingestors::MarketplaceIngestor.new(
          tenant: tenant, platform_account: conta, start_date: DE, end_date: ATE
        ).call
      end

      com_metodo(Providers::ShopeeProvider, :financial_events,
                 ->(start_date:, end_date:) { fixos }) do
        com_metodo(Providers::ShopeeProvider.singleton_class, :configured?, ->(_c) { true }) do
          assert_equal fixos.size, ingerir.call[:created]

          persistidos = FinancialEntry.where(tenant: tenant).where("external_id LIKE 'SHOPEE-%'")

          assert_equal fixos.size, persistidos.count
          assert_equal 1, persistidos.sales.count
          assert_operator persistidos.fees.count, :>, 0
          assert_operator persistidos.where.not(order_id: nil).count, :>, 0

          assert_equal 0, ingerir.call[:created]
        end
      end
    end
  end
end
