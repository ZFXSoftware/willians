require "test_helper"

module Marketplace
  # O faturamento do ML fecha por período: encargos e bonificações só existem
  # quando o período está CLOSED. Ingerir período aberto significa lançar valor
  # que ainda vai mudar.
  class MercadoLivreBillingTest < ActiveSupport::TestCase
    ML = Marketplace::MercadoLivre

    # Respostas no formato da documentação do Mercado Livre.
    PERIODS = [
      { "amount" => 30.46, "unpaid_amount" => 0.0,
        "period" => { "date_from" => "2026-06-19", "date_to" => "2026-07-18" },
        "key" => "2026-07-01", "expiration_date" => "2026-07-24", "period_status" => "CLOSED" },
      { "amount" => 12.0, "unpaid_amount" => 12.0,
        "period" => { "date_from" => "2026-07-19", "date_to" => "2026-08-18" },
        "key" => "2026-08-01", "expiration_date" => "2026-08-24", "period_status" => "OPEN" },
      { "amount" => 99.0, "unpaid_amount" => 0.0,
        "period" => { "date_from" => "2020-02-19", "date_to" => "2020-03-18" },
        "key" => "2020-03-01", "expiration_date" => "2020-03-24", "period_status" => "CLOSED" }
    ].freeze

    SUMMARY = {
      "user" => { "nickname" => "TEST" },
      "period" => { "date_from" => "2026-06-19", "date_to" => "2026-07-18",
                    "expiration_date" => "2026-07-24", "key" => "2026-07-01" },
      "bill_includes" => {
        "total_amount" => 171_070_532.64,
        "total_perceptions" => 33_077_380.48,
        "bonuses" => [
          { "label" => "Bonificação cargo por Mercado Envios", "amount" => 385_261.63, "type" => "BXD", "groupId" => 3 },
          { "label" => "Bonificação do cargo por venda", "amount" => 6_123_337.46, "type" => "BXD", "groupId" => 4 }
        ],
        "charges" => [
          { "label" => "Campanhas de publicidade - Product Ads", "amount" => 48_600, "type" => "PADS", "groupId" => 24 },
          { "label" => "Cargo por Mercado Envios", "amount" => 11_195_255.36, "type" => "CXD", "groupId" => 24 },
          { "label" => "Cargo por venda", "amount" => 131_285_530.48, "type" => "CV", "groupId" => 28 }
        ]
      },
      "payment_collected" => { "operation_discount" => 136_492_738.16, "total_payment" => 33_353_689.85,
                               "total_credit_note" => 1_989_281, "total_collected" => 171_070_532.64,
                               "total_debt" => 0.0 },
      "errors" => []
    }.freeze

    DE = Date.new(2026, 7, 1)

    ATE = Date.new(2026, 8, 7)

    class BillingFalso
      attr_reader :summary_calls,
                  :period_calls

      def initialize
        @summary_calls = []
        @period_calls = []
      end

      def periods(group: nil, **)
        @period_calls << group

        PERIODS
      end

      def summary(key:, group: nil)
        @summary_calls << [group, key]

        SUMMARY
      end
    end

    def eventos(client = BillingFalso.new, grupos: %w[ML])
      ML::BillingEvents.new(client: client, groups: grupos).call(start_date: DE, end_date: ATE)
    end

    test "ingere só período fechado dentro da janela" do
      falso = BillingFalso.new
      eventos(falso)

      assert_equal ["ML"], falso.period_calls
      # O período OPEN ainda muda; o de 2020 está fora da janela pedida.
      assert_equal [["ML", "2026-07-01"]], falso.summary_calls
    end

    test "encargo vira taxa a débito e bonificação vira ajuste a crédito" do
      lista = eventos
      taxas = lista.select { |e| e[:entry_type] == :fee }
      ajustes = lista.select { |e| e[:entry_type] == :adjustment }

      assert_equal 3, taxas.size
      assert taxas.all? { |e| e[:direction] == :debit }
      assert_equal 2, ajustes.size
      assert ajustes.all? { |e| e[:direction] == :credit }
      assert lista.all? { |e| e[:amount].positive? }, "valor guardado sempre positivo"

      cargo_por_venda = taxas.find { |e| e[:external_id].include?("CV-28") }

      assert_equal BigDecimal("131285530.48"), cargo_por_venda[:amount]
    end

    test "bonificações do mesmo tipo em grupos diferentes não se fundem" do
      bxd = eventos.select { |e| e[:entry_type] == :adjustment && e[:external_id].include?("BXD") }

      assert_equal 2, bxd.size, "BXD-3 e BXD-4 são lançamentos distintos"
    end

    test "external_id é estável entre execuções e único" do
      primeira = eventos
      segunda = eventos

      assert_equal primeira.map { |e| e[:external_id] }.sort, segunda.map { |e| e[:external_id] }.sort
      assert_equal primeira.size, primeira.map { |e| e[:external_id] }.uniq.size
    end

    test "ML e MP são consultados separadamente e não colidem" do
      falso = BillingFalso.new
      ambos = eventos(falso, grupos: %w[ML MP])

      assert_equal %w[ML MP], falso.summary_calls.map(&:first).sort
      assert_equal ambos.size, ambos.map { |e| e[:external_id] }.uniq.size
    end

    test "chave do período muda no México" do
      assert_equal "2026-07-01", ML::BillingClient.period_key_for(PERIODS[0])
      assert_equal "2026-07-24", ML::BillingClient.period_key_for(PERIODS[0], site_id: "MLM")
    end

    test "parâmetros inválidos falham antes de chegar na rede" do
      client = ML::BillingClient.new(access_token: "x")

      assert_includes assert_raises(ArgumentError) { client.periods(group: "XX") }.message, "ML"
      assert_includes assert_raises(ArgumentError) {
        client.periods(group: "ML", document_type: "NOTA")
      }.message, "BILL"
    end

    test "faturamento vira lançamento sem pedido e não duplica" do
      tenant = criar_tenant
      conta = criar_conta(tenant: tenant)
      fixos = eventos

      ingerir = lambda do
        Ingestors::MarketplaceIngestor.new(
          tenant: tenant, platform_account: conta, start_date: DE, end_date: ATE
        ).call
      end

      com_metodo(Providers::MercadoLivreProvider, :financial_events,
                 ->(start_date:, end_date:) { fixos }) do
        com_metodo(Providers::MercadoLivreProvider.singleton_class, :configured?, ->(_conta) { true }) do
          ingerir.call

          persistidos = FinancialEntry.where(tenant: tenant).where("external_id LIKE 'MLBILL-%'")

          assert_equal fixos.size, persistidos.count
          assert_equal 3, persistidos.fees.where(direction: :debit).count
          # Faturamento é por período, não por venda: não há pedido para amarrar.
          assert_equal 0, persistidos.where.not(order_id: nil).count

          assert_equal 0, ingerir.call[:created]
          assert_equal fixos.size, persistidos.count
        end
      end
    end
  end
end
