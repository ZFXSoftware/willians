require "test_helper"

module Marketplace
  # A carteira é a segunda metade do dinheiro da Shopee: o saque para o banco e
  # o que não passa por pedido. O risco aqui é somar duas vezes — o escrow do
  # pedido TAMBÉM aparece na carteira, como ESCROW_VERIFIED_ADD.
  class ShopeeWalletTest < ActiveSupport::TestCase
    S = Marketplace::Shopee

    DE = Date.new(2026, 8, 1)

    ATE = Date.new(2026, 8, 7)

    def transacao(tipo, valor, extras = {})
      {
        "status" => "COMPLETED",
        "transaction_type" => tipo,
        "amount" => valor,
        "current_balance" => 5000.0,
        "create_time" => 1_651_849_648,
        "money_flow" => valor.negative? ? "MONEY_OUT" : "MONEY_IN"
      }.merge(extras)
    end

    def eventos(*transacoes)
      leitor = S::WalletEvents.new(transacoes)

      [leitor.call, leitor]
    end

    # -------------------------------------------- o risco de contar duas vezes

    test "o escrow do pedido NÃO entra pela carteira" do
      lista, = eventos(
        transacao("ESCROW_VERIFIED_ADD", 170.0, "order_sn" => "220415N6SB140P"),
        transacao("FAST_ESCROW_DISBURSE", 100.0),
        transacao("WITHDRAWAL_COMPLETED", -1000.0, "withdrawal_id" => 987)
      )

      # Só o saque sobra: o escrow já foi decomposto em venda e taxas.
      assert_equal 1, lista.size
      assert_equal :settlement, lista.first[:entry_type]
    end

    test "saque concluído vira liquidação; a criação do saque é só reserva" do
      lista, = eventos(
        transacao("WITHDRAWAL_CREATED", -1000.0, "withdrawal_id" => 987),
        transacao("WITHDRAWAL_COMPLETED", -1000.0, "withdrawal_id" => 987)
      )

      assert_equal 1, lista.size, "contar os dois lançaria o saque em dobro"

      saque = lista.first

      assert_equal :settlement, saque[:entry_type]
      assert_equal :debit, saque[:direction]
      assert_equal BigDecimal("1000.0"), saque[:amount]
      assert_equal "SHOPEE-WALLET-WITHDRAWAL_COMPLETED-987", saque[:external_id]
    end

    test "saque cancelado devolve o dinheiro" do
      lista, = eventos(transacao("WITHDRAWAL_CANCELLED", 1000.0, "withdrawal_id" => 987))

      assert_equal :credit, lista.first[:direction]
      assert_equal :adjustment, lista.first[:entry_type]
    end

    # ------------------------------------------------------------- os demais

    test "anúncios e afiliados viram taxa" do
      lista, = eventos(
        transacao("PAID_ADS_CHARGE", -50.0),
        transacao("AFFILIATE_FEE_DEDUCT", -20.0),
        transacao("PAID_ADS_REFUND", 10.0)
      )

      assert_equal %i[fee fee adjustment], lista.map { |e| e[:entry_type] }
      assert_equal %i[debit debit credit], lista.map { |e| e[:direction] }
    end

    test "ajuste guarda o motivo informado pela Shopee" do
      lista, = eventos(
        transacao("ADJUSTMENT_MINUS", -30.0, "reason" => "DRC commission fee adjustment",
                                             "order_sn" => "220322JUMMT0S0")
      )

      assert_equal "DRC commission fee adjustment", lista.first[:description]
      assert_equal "220322JUMMT0S0", lista.first[:external_order_id]
    end

    test "money_flow tem a palavra final sobre a direção" do
      # Tipo que a nossa tabela diz ser crédito, mas a Shopee marca como saída.
      lista, = eventos(transacao("ADJUSTMENT_ADD", 30.0).merge("money_flow" => "MONEY_OUT"))

      assert_equal :debit, lista.first[:direction]
    end

    test "movimentação não concluída não entra no razão" do
      lista, leitor = eventos(
        transacao("PAID_ADS_CHARGE", -50.0).merge("status" => "PENDING"),
        transacao("PAID_ADS_CHARGE", -60.0).merge("status" => "FAILED")
      )

      assert_empty lista
      assert_equal 2, leitor.pendentes
    end

    test "tipo desconhecido é contado, não engolido" do
      _, leitor = eventos(transacao("TIPO_QUE_A_SHOPEE_INVENTOU", -10.0))

      assert_equal({ "TIPO_QUE_A_SHOPEE_INVENTOU" => 1 }, leitor.ignorados)
    end

    # -------------------------------------------------------- saldo (2.4)

    test "o saldo declarado vem da movimentação mais recente" do
      _, leitor = eventos(
        transacao("PAID_ADS_CHARGE", -50.0).merge("current_balance" => 1000.0,
                                                  "create_time" => 1_651_000_000),
        transacao("WITHDRAWAL_COMPLETED", -100.0).merge("current_balance" => 900.0,
                                                        "create_time" => 1_651_999_999,
                                                        "withdrawal_id" => 1)
      )

      assert_equal BigDecimal("900.0"), leitor.saldo[:valor]
      assert_equal Time.zone.at(1_651_999_999), leitor.saldo[:em]
    end

    test "sem movimentação não há saldo declarado" do
      _, leitor = eventos

      assert_nil leitor.saldo
    end

    # ------------------------------------------------- janelas e paginação

    class ClienteFalso
      attr_reader :chamadas

      def initialize(paginas)
        @paginas = paginas
        @chamadas = []
      end

      def get(chave, params = {})
        @chamadas << [chave, params]

        @paginas.shift || { "response" => { "more" => false, "transaction_list" => [] } }
      end
    end

    test "período maior que 15 dias é quebrado em janelas" do
      cliente = ClienteFalso.new([])

      janelas = S::WalletReader.new(client: cliente)
                               .janelas(Date.new(2026, 1, 1), Date.new(2026, 2, 5))

      assert_equal 3, janelas.size, "a API recusa janela maior que 15 dias"
      assert_equal Date.new(2026, 1, 1), janelas.first.first
      assert_equal Date.new(2026, 1, 15), janelas.first.last
      assert_equal Date.new(2026, 2, 5), janelas.last.last

      # Sem buraco nem sobreposição entre as janelas.
      janelas.each_cons(2) { |(_, fim), (inicio, _)| assert_equal fim + 1.day, inicio }
    end

    test "a paginação da carteira começa em zero" do
      cliente = ClienteFalso.new([
        { "response" => { "more" => true, "transaction_list" => [] } },
        { "response" => { "more" => false, "transaction_list" => [] } }
      ])

      S::WalletReader.new(client: cliente).call(start_date: DE, end_date: ATE)

      paginas = cliente.chamadas.map { |_, p| p[:page_no] }

      # A de escrow_list começa em 1; esta começa em 0. Trocar devolve erro.
      assert_equal [0, 1], paginas
      assert_equal 100, cliente.chamadas.first.last[:page_size]
    end

    test "o filtro é por create_time em timestamp Unix" do
      cliente = ClienteFalso.new([])

      S::WalletReader.new(client: cliente).call(start_date: DE, end_date: ATE)

      params = cliente.chamadas.first.last

      assert_equal DE.beginning_of_day.to_i, params[:create_time_from]
      assert_equal ATE.end_of_day.to_i, params[:create_time_to]
    end
  end
end
