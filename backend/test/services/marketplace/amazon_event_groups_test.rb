require "test_helper"

module Marketplace
  # A Amazon não tem carteira com saldo: tem ciclos. Um grupo fica ABERTO
  # acumulando o que ela deve, e ao fechar o dinheiro vai para o banco. Chamar
  # o acumulado de "saldo disponível" seria mentira — não é dinheiro sacável.
  class AmazonEventGroupsTest < ActiveSupport::TestCase
    A = Marketplace::Amazon

    DE = Date.new(2026, 8, 1)

    ATE = Date.new(2026, 8, 31)

    def grupo(id, extras = {})
      {
        "FinancialEventGroupId" => id,
        "ProcessingStatus" => "Closed",
        "FundTransferStatus" => "Successful",
        "OriginalTotal" => { "CurrencyCode" => "BRL", "CurrencyAmount" => 1500.0 },
        "FundTransferDate" => "2026-08-15T10:00:00Z",
        "AccountTail" => "1234",
        "TraceId" => "TR-1",
        "FinancialEventGroupStart" => "2026-08-01T00:00:00Z",
        "FinancialEventGroupEnd" => "2026-08-14T23:59:59Z"
      }.merge(extras)
    end

    class ClienteFalso
      attr_reader :chamadas

      def initialize(paginas)
        @paginas = paginas
        @chamadas = []
      end

      def get(path, params = {})
        @chamadas << [path, params]

        @paginas.shift || { "payload" => { "FinancialEventGroupList" => [] } }
      end
    end

    def ler(grupos, cliente: nil)
      cliente ||= ClienteFalso.new([{ "payload" => { "FinancialEventGroupList" => grupos } }])

      [A::EventGroups.new(client: cliente).call(start_date: DE, end_date: ATE), cliente]
    end

    # ------------------------------------------------------------- o saque

    test "grupo transferido vira liquidação" do
      resultado, = ler([grupo("G1")])

      saque = resultado.saques.first

      assert_equal "AMZ-PAYOUT-G1", saque[:external_id]
      assert_equal :settlement, saque[:entry_type]
      assert_equal :debit, saque[:direction]
      assert_equal BigDecimal("1500.0"), saque[:amount]
      assert_equal Time.zone.parse("2026-08-15T10:00:00Z"), saque[:occurred_at]
      assert_equal "1234", saque[:metadata]["account_tail"]
    end

    test "sem data de transferência não houve saque" do
      resultado, = ler([grupo("G1", "FundTransferDate" => nil)])

      assert_empty resultado.saques, "grupo fechado mas não transferido ainda"
    end

    test "transferência que falhou não vira saque" do
      %w[Failed Cancelled RejectedByBank].each do |status|
        resultado, = ler([grupo("G1", "FundTransferStatus" => status)])

        assert_empty resultado.saques, "#{status} não deveria contar como saque"
      end
    end

    test "ciclo negativo é a Amazon cobrando do vendedor" do
      resultado, = ler([grupo("G1", "OriginalTotal" => { "CurrencyCode" => "BRL",
                                                         "CurrencyAmount" => -320.0 })])

      saque = resultado.saques.first

      assert_equal :credit, saque[:direction], "dinheiro entrando na conta virtual, não saindo"
      assert_equal BigDecimal("320.0"), saque[:amount]
    end

    test "grupo sem total não vira lançamento" do
      # Acontece de verdade: há relato de grupo fechado vindo sem OriginalTotal.
      resultado, = ler([grupo("G1", "OriginalTotal" => nil)])

      assert_empty resultado.saques
    end

    # ---------------------------------------------------- o ciclo aberto

    test "o ciclo aberto é o que a Amazon tem a pagar" do
      resultado, = ler([
        grupo("FECHADO"),
        grupo("ABERTO", "ProcessingStatus" => "Open", "FundTransferDate" => nil,
                        "OriginalTotal" => { "CurrencyCode" => "BRL", "CurrencyAmount" => 800.0 })
      ])

      assert_equal "ABERTO", resultado.aberto["FinancialEventGroupId"]

      a_receber = A::EventGroups.a_receber(resultado.aberto)

      assert_equal BigDecimal("800.0"), a_receber[:valor]
      assert_equal "BRL", a_receber[:moeda]
    end

    test "ciclo recém-aberto cai no saldo inicial" do
      recem = grupo("NOVO", "ProcessingStatus" => "Open", "OriginalTotal" => nil,
                            "BeginningBalance" => { "CurrencyCode" => "BRL", "CurrencyAmount" => 120.0 })

      assert_equal BigDecimal("120.0"), A::EventGroups.a_receber(recem)[:valor]
    end

    test "sem ciclo aberto não há o que reportar" do
      resultado, = ler([grupo("G1")])

      assert_nil resultado.aberto
      assert_nil A::EventGroups.a_receber(nil)
    end

    # ------------------------------------------------------- requisição

    test "filtra por data de início do ciclo, em ISO 8601" do
      _, cliente = ler([])

      caminho, params = cliente.chamadas.first

      assert_equal "/finances/v0/financialEventGroups", caminho
      assert_equal 100, params[:MaxResultsPerPage]
      assert_match(/\A2026-08-01T\d{2}:\d{2}:\d{2}Z\z/, params[:FinancialEventGroupStartedAfter])
      assert_match(/\A2026-08-31T\d{2}:\d{2}:\d{2}Z\z/, params[:FinancialEventGroupStartedBefore])
      refute params.key?(:NextToken), "a primeira página não leva token"
    end

    test "segue o NextToken até acabar" do
      cliente = ClienteFalso.new([
        { "payload" => { "FinancialEventGroupList" => [grupo("G1")], "NextToken" => "T1" } },
        { "payload" => { "FinancialEventGroupList" => [grupo("G2")] } }
      ])

      resultado, = ler(nil, cliente: cliente)

      assert_equal 2, resultado.grupos
      assert_equal "T1", cliente.chamadas.last.last[:NextToken]
    end

    # --------------------------------------- integração com o provider

    test "o provider soma os saques aos eventos financeiros" do
      provider = Providers::AmazonProvider.allocate

      provider.define_singleton_method(:grupos) do |start_date:, end_date:|
        A::EventGroups::Resultado.new(saques: [{ external_id: "AMZ-PAYOUT-G1" }], aberto: nil, grupos: 1)
      end

      provider.define_singleton_method(:client) { nil }

      eventos_falsos = [{ external_id: "AMZ-SHIP-1" }]

      com_metodo(A::FinancialEvents, :call, ->(start_date:, end_date:) { eventos_falsos }) do
        resultado = provider.financial_events(start_date: DE, end_date: ATE)

        assert_equal %w[AMZ-SHIP-1 AMZ-PAYOUT-G1], resultado.map { |e| e[:external_id] }
      end
    end

    test "o saldo da Amazon vai como FUTURO, nunca como disponível" do
      provider = Providers::AmazonProvider.allocate

      aberto = grupo("ABERTO", "ProcessingStatus" => "Open",
                               "OriginalTotal" => { "CurrencyCode" => "BRL", "CurrencyAmount" => 800.0 })

      provider.define_singleton_method(:grupos) do |start_date:, end_date:|
        A::EventGroups::Resultado.new(saques: [], aberto: aberto, grupos: 1)
      end

      saldo = provider.account_balance(start_date: DE, end_date: ATE)

      # O ponto: na Amazon não existe dinheiro parado e sacável.
      assert_nil saldo[:available]
      assert_equal BigDecimal("800.0"), saldo[:future]
      assert_equal "ciclo_aberto_amazon", saldo[:source]
    end
  end
end
