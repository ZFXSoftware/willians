require "test_helper"

module Marketplace
  # A SP-API entrega os eventos em listas separadas por tipo, cada uma com
  # formato próprio, e a direção do dinheiro vem só no SINAL do valor. A
  # normalização é onde o dinheiro do cliente pode entrar invertido.
  class AmazonTest < ActiveSupport::TestCase
    A = Marketplace::Amazon

    # Copiado do formato real da API. Traz de propósito um pedido com dois
    # itens, um estorno e uma lista que não tratamos.
    PAYLOAD = {
      "payload" => {
        "FinancialEvents" => {
          "ShipmentEventList" => [{
            "AmazonOrderId" => "701-1234567-1234567",
            "PostedDate" => "2026-08-01T10:00:00Z",
            "ShipmentItemList" => [
              { "SellerSKU" => "SKU-1",
                "ItemChargeList" => [{ "ChargeType" => "Principal",
                                       "ChargeAmount" => { "CurrencyCode" => "BRL", "CurrencyAmount" => 100.0 } }],
                "ItemFeeList" => [{ "FeeType" => "Commission",
                                    "FeeAmount" => { "CurrencyCode" => "BRL", "CurrencyAmount" => -15.0 } }] },
              { "SellerSKU" => "SKU-2",
                "ItemChargeList" => [{ "ChargeType" => "Principal",
                                       "ChargeAmount" => { "CurrencyCode" => "BRL", "CurrencyAmount" => 50.0 } }],
                "ItemFeeList" => [] }
            ]
          }],
          "RefundEventList" => [{
            "AmazonOrderId" => "701-7777777-7777777",
            "PostedDate" => "2026-08-02T10:00:00Z",
            "ShipmentItemList" => [
              { "ItemChargeList" => [{ "ChargeType" => "Principal",
                                       "ChargeAmount" => { "CurrencyCode" => "BRL", "CurrencyAmount" => -30.0 } }],
                "ItemFeeList" => [{ "FeeType" => "Commission",
                                    "FeeAmount" => { "CurrencyCode" => "BRL", "CurrencyAmount" => 4.5 } }] }
            ]
          }],
          "ServiceFeeEventList" => [{
            "AmazonOrderId" => "701-1234567-1234567",
            "PostedDate" => "2026-08-03T10:00:00Z",
            "FeeReason" => "FBAInboundDefect",
            "FeeList" => [{ "FeeType" => "FBAInboundDefect",
                            "FeeAmount" => { "CurrencyCode" => "BRL", "CurrencyAmount" => -2.5 } }]
          }],
          "AdjustmentEventList" => [{
            "AdjustmentType" => "ReserveCredit",
            "PostedDate" => "2026-08-04T10:00:00Z",
            "AdjustmentAmount" => { "CurrencyCode" => "BRL", "CurrencyAmount" => 12.34 }
          }],
          "CouponPaymentEventList" => [{ "PostedDate" => "2026-08-05T10:00:00Z" }]
        },
        "NextToken" => nil
      }
    }.freeze

    DE = Date.new(2026, 8, 1)

    ATE = Date.new(2026, 8, 7)

    # Dublê da SP-API que devolve sempre o mesmo payload.
    class SpApiFalsa
      attr_reader :chamadas

      def initialize(payload)
        @payload = payload
        @chamadas = []
      end

      def get(path, params = {})
        @chamadas << [path, params]

        @payload
      end
    end

    setup do
      @env_anterior = ENV.to_h.slice("AMAZON_CLIENT_ID", "AMAZON_CLIENT_SECRET", "AMAZON_APP_ID",
                                     "AMAZON_HOST", "AMAZON_REGION", "APP_PUBLIC_URL")

      ENV["AMAZON_CLIENT_ID"] = "amzn1.application-oa2-client.teste"
      ENV["AMAZON_CLIENT_SECRET"] = "segredo-lwa"
      ENV["AMAZON_APP_ID"] = "amzn1.sp.solution.teste"
      ENV["AMAZON_REGION"] = "na"
      ENV["APP_PUBLIC_URL"] = "https://teste.ngrok-free.dev"
      ENV.delete("AMAZON_HOST")

      @tenant = criar_tenant
      @usuario = criar_usuario(tenant: @tenant)
    end

    teardown do
      %w[AMAZON_CLIENT_ID AMAZON_CLIENT_SECRET AMAZON_APP_ID AMAZON_HOST AMAZON_REGION
         APP_PUBLIC_URL].each do |k|
        @env_anterior.key?(k) ? ENV[k] = @env_anterior[k] : ENV.delete(k)
      end
    end

    def eventos
      @eventos ||= A::FinancialEvents.new(client: SpApiFalsa.new(PAYLOAD)).call(start_date: DE, end_date: ATE)
    end

    def conectar
      resultado = A::Authorization.new(tenant: @tenant, user: @usuario).call

      A::Callback.new(code: "SPAPI-CODE", selling_partner_id: "A1SELLER99",
                      state: resultado[:state], client: OauthFalso.new(expires_in: 3600, prefixo: "A")).call
    end

    # ------------------------------------------------------------ região e OAuth

    test "região aponta para o endpoint certo e o consentimento é o do Brasil" do
      assert_equal "https://sellingpartnerapi-na.amazon.com", A::Settings.host

      com_env("AMAZON_REGION" => "eu") do
        assert_equal "https://sellingpartnerapi-eu.amazon.com", A::Settings.host
      end

      assert A::Settings.consent_url.start_with?("https://sellercentral.amazon.com.br/apps/authorize/consent")
    end

    test "autorização vai ao Seller Central com application_id e state próprio" do
      resultado = A::Authorization.new(tenant: @tenant, user: @usuario).call
      url = URI.parse(resultado[:authorization_url])
      query = URI.decode_www_form(url.query).to_h

      assert_equal "sellercentral.amazon.com.br", url.host
      assert_equal ENV["AMAZON_APP_ID"], query["application_id"]
      # Diferente da Shopee, aqui o state é parâmetro de primeira classe.
      assert_equal resultado[:state], query["state"]

      esperado = "#{ENV['APP_PUBLIC_URL']}/api/integracoes/amazon/callback"

      assert_equal esperado, query["redirect_uri"]
      assert_equal esperado, A::Settings.redirect_uri
    end

    test "callback conecta a conta pelo selling_partner_id" do
      credencial = conectar

      assert_equal "A1SELLER99", credencial.platform_account.external_id
      assert_equal "amazon", credencial.platform_account.platform
      assert_in_delta 3600, credencial.expires_at - Time.current, 200, "LWA dura 1h"

      bruto = ActiveRecord::Base.connection.select_value(
        "SELECT access_token FROM marketplace_credentials WHERE id = #{credencial.id}"
      ).to_s

      refute_includes bruto, "AAT-1"
    end

    test "state do callback é de uso único" do
      resultado = A::Authorization.new(tenant: @tenant, user: @usuario).call
      falso = OauthFalso.new(expires_in: 3600, prefixo: "A")

      A::Callback.new(code: "SPAPI-CODE", selling_partner_id: "A1SELLER99",
                      state: resultado[:state], client: falso).call

      assert_raises(A::Callback::InvalidState) do
        A::Callback.new(code: "X", selling_partner_id: "A1SELLER99",
                        state: resultado[:state], client: falso).call
      end
    end

    # ------------------------------------------------------------- normalização

    test "consulta o endpoint de eventos financeiros com a janela de datas" do
      api = SpApiFalsa.new(PAYLOAD)
      A::FinancialEvents.new(client: api).call(start_date: DE, end_date: ATE)

      assert_equal "/finances/v0/financialEvents", api.chamadas.first[0]
      assert_equal %i[MaxResultsPerPage NextToken PostedAfter PostedBefore],
                   api.chamadas.first[1].keys.sort
    end

    test "itens do mesmo pedido somam em um lançamento só" do
      venda = eventos.index_by { |e| e[:external_id] }
                     .fetch("AMZ-SHIP-701-1234567-1234567-2026-08-01T10:00:00Z-Principal")

      assert_equal BigDecimal("150.0"), venda[:amount], "100 + 50 do mesmo pedido"
      assert_equal :credit, venda[:direction]
      assert_equal :sale, venda[:entry_type]
      assert_equal "701-1234567-1234567", venda[:external_order_id]
    end

    test "o sinal do valor define a direção, e o valor é sempre positivo" do
      por_id = eventos.index_by { |e| e[:external_id] }

      taxa = por_id.fetch("AMZ-SHIPFEE-701-1234567-1234567-2026-08-01T10:00:00Z-Commission")

      assert_equal :debit, taxa[:direction]
      assert_equal BigDecimal("15.0"), taxa[:amount], "guardamos o módulo, a direção diz o resto"

      # Estorno de taxa chega POSITIVO: é dinheiro voltando.
      estorno = eventos.find { |e| e[:external_id].include?("REFUNDFEE") }

      assert_equal :credit, estorno[:direction]

      servico = eventos.find { |e| e[:external_id].start_with?("AMZ-SERVICEFEE") }

      assert_equal :fee, servico[:entry_type]
      assert_equal BigDecimal("2.5"), servico[:amount]

      ajuste = eventos.find { |e| e[:external_id].start_with?("AMZ-ADJ") }

      assert_equal :credit, ajuste[:direction]
      assert_equal BigDecimal("12.34"), ajuste[:amount]
    end

    test "lista não tratada é contada, não engolida em silêncio" do
      leitor = A::FinancialEvents.new(client: SpApiFalsa.new(PAYLOAD))
      leitor.call(start_date: DE, end_date: ATE)

      assert_equal({ "CouponPaymentEventList" => 1 }, leitor.ignorados)
    end

    test "external_id é estável entre execuções e único dentro de uma" do
      outra = A::FinancialEvents.new(client: SpApiFalsa.new(PAYLOAD)).call(start_date: DE, end_date: ATE)

      assert_equal eventos.map { |e| e[:external_id] }.sort, outra.map { |e| e[:external_id] }.sort
      assert_equal eventos.size, eventos.map { |e| e[:external_id] }.uniq.size
    end

    # ------------------------------------------------------------- persistência

    test "eventos normalizados viram lançamentos, sem duplicar na reingestão" do
      conta = conectar.platform_account
      fixos = eventos

      ingerir = lambda do
        Ingestors::MarketplaceIngestor.new(
          tenant: @tenant, platform_account: conta, start_date: DE, end_date: ATE
        ).call
      end

      com_metodo(Providers::AmazonProvider, :financial_events,
                 ->(start_date:, end_date:) { fixos }) do
        com_metodo(Providers::AmazonProvider.singleton_class, :configured?, ->(_conta) { true }) do
          primeiro = ingerir.call
          persistidos = FinancialEntry.where(tenant: @tenant).where("external_id LIKE 'AMZ-%'")

          assert_equal fixos.size, primeiro[:created]
          assert_equal fixos.size, persistidos.count
          assert_operator persistidos.where.not(order_id: nil).count, :>=, 4

          assert_equal 0, ingerir.call[:created], "reingestão não pode duplicar"
        end
      end
    end

    # ------------------------------------------------------------------ recusas

    test "recusa DEFINITIVA de qualquer plataforma é reconhecível por um tipo só" do
      [MercadoLivre::OauthClient::TokenRejected.new("x"),
       Shopee::Client::AuthError.new("x"),
       A::OauthClient::TokenRejected.new("x")].each do |erro|
        assert_kind_of Marketplace::TokenRefreshRejected, erro,
                       "#{erro.class} precisa ser tratável como recusa de renovação"
      end
    end

    # O contrário importa mais: era isto que desconectava a conta do lojista
    # quando a plataforma dava 500, 429 ou uma instabilidade de dez segundos.
    test "erro passageiro NÃO se disfarça de recusa definitiva" do
      [MercadoLivre::OauthClient::TokenError.new("500"),
       Shopee::Client::ApiError.new("error_server", code: "error_server"),
       A::OauthClient::TokenError.new("500")].each do |erro|
        assert_not_kind_of Marketplace::TokenRefreshRejected, erro,
                           "#{erro.class} passageiro não pode custar um OAuth novo ao lojista"
      end
    end
  end
end
