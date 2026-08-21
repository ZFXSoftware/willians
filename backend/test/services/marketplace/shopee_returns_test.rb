require "test_helper"

module Marketplace
  # Briefing 2.8 pela fonte da própria Shopee: motivo, estado da negociação e
  # o pedido de origem, que é o elo com a venda e a nota fiscal.
  class ShopeeReturnsTest < ActiveSupport::TestCase
    S = Marketplace::Shopee

    DE = Date.new(2026, 8, 1)

    ATE = Date.new(2026, 8, 7)

    # Resposta no formato da documentação.
    REGISTRO = {
      "return_sn" => "200203171852695",
      "order_sn" => "200203C6W0AR27",
      "refund_amount" => 1409.0,
      "currency" => "BRL",
      "create_time" => 1_580_721_513,
      "update_time" => 1_580_729_377,
      "status" => "REQUESTED",
      "reason" => "PHYSICAL_DMG",
      "text_reason" => "chegou quebrado",
      "reassessed_request_reason" => "NONE",
      "dispute_reason" => ["UNKNOWN"],
      "negotiation_status" => "PENDING_RESPOND",
      "return_seller_due_date" => 1_655_438_336,
      "return_solution" => 0,
      "tracking_number" => "RNSHS00177569"
    }.freeze

    class ClienteFalso
      attr_reader :chamadas

      def initialize(paginas)
        @paginas = paginas
        @chamadas = []
      end

      def get(chave, params = {})
        @chamadas << [chave, params]

        @paginas.shift || { "response" => { "more" => false, "return" => [] } }
      end
    end

    def ler(registros, mais: false)
      cliente = ClienteFalso.new([{ "response" => { "more" => mais, "return" => registros } }])

      [S::ReturnReader.new(client: cliente).call(start_date: DE, end_date: ATE), cliente]
    end

    test "traz o pedido de origem, que é o elo com a venda" do
      lista, = ler([REGISTRO])

      devolucao = lista.first

      assert_equal "200203171852695", devolucao[:return_sn]
      assert_equal "200203C6W0AR27", devolucao[:order_sn]
      assert_equal BigDecimal("1409.0"), devolucao[:valor]
      assert_equal "chegou quebrado", devolucao[:motivo_livre]
      assert devolucao[:devolve_mercadoria], "return_solution 0 devolve a mercadoria"
      refute devolucao[:encerrado], "REQUESTED ainda está em aberto"
    end

    test "motivo reavaliado pela Shopee vence o original" do
      registro = REGISTRO.merge("reassessed_request_reason" => "ITEM_MISSING")

      lista, = ler([registro])

      assert_equal "ITEM_MISSING", lista.first[:motivo],
                   "a Shopee reavalia depois de ver as provas; vale o novo"
    end

    test "NONE não é motivo reavaliado" do
      lista, = ler([REGISTRO])

      assert_equal "PHYSICAL_DMG", lista.first[:motivo]
    end

    test "UNKNOWN não conta como disputa" do
      lista, = ler([REGISTRO])

      assert_nil lista.first[:disputa]

      com_disputa, = ler([REGISTRO.merge("dispute_reason" => %w[NOT_RECEIVED])])

      assert_equal %w[NOT_RECEIVED], com_disputa.first[:disputa]
    end

    test "status encerrado é reconhecido" do
      lista, = ler([REGISTRO.merge("status" => "CANCELLED")])

      assert lista.first[:encerrado]
    end

    test "só reembolso, sem mercadoria de volta" do
      lista, = ler([REGISTRO.merge("return_solution" => 1)])

      refute lista.first[:devolve_mercadoria]
    end

    test "a paginação começa em zero e o filtro é em timestamp" do
      _, cliente = ler([REGISTRO])

      params = cliente.chamadas.first.last

      assert_equal 0, params[:page_no]
      assert_equal 100, params[:page_size]
      assert_equal DE.beginning_of_day.to_i, params[:create_time_from]
      assert_equal ATE.end_of_day.to_i, params[:create_time_to]
    end

    test "período maior que 15 dias vira mais de uma consulta" do
      cliente = ClienteFalso.new([])

      S::ReturnReader.new(client: cliente).call(start_date: Date.new(2026, 1, 1),
                                                end_date: Date.new(2026, 2, 5))

      janelas = cliente.chamadas.map { |_, p| p[:create_time_from] }.uniq

      assert_equal 3, janelas.size
    end
  end
end
