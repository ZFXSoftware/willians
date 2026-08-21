require "test_helper"
require "openssl"

module Marketplace
  # A Shopee assina cada requisição com HMAC-SHA256 sobre uma base string de
  # ordem fixa. Errar a ordem ou o escopo derruba toda a integração, e o erro
  # que ela devolve não diz qual campo está errado — daí a cobertura miúda.
  class ShopeeTest < ActiveSupport::TestCase
    S = Marketplace::Shopee

    PARTNER_ID = "2001234".freeze

    PARTNER_KEY = "chave-secreta-de-teste".freeze

    setup do
      @assinatura = S::Signature.new(partner_id: PARTNER_ID, partner_key: PARTNER_KEY)
      @env_anterior = ENV.to_h.slice("SHOPEE_PARTNER_ID", "SHOPEE_PARTNER_KEY", "SHOPEE_HOST",
                                     "SHOPEE_REGION", "APP_PUBLIC_URL")

      ENV["SHOPEE_PARTNER_ID"] = PARTNER_ID
      ENV["SHOPEE_PARTNER_KEY"] = PARTNER_KEY
      ENV["SHOPEE_REGION"] = "br"
      ENV["APP_PUBLIC_URL"] = "https://teste.ngrok-free.dev"
      ENV.delete("SHOPEE_HOST")
    end

    teardown do
      %w[SHOPEE_PARTNER_ID SHOPEE_PARTNER_KEY SHOPEE_HOST SHOPEE_REGION APP_PUBLIC_URL].each do |k|
        @env_anterior.key?(k) ? ENV[k] = @env_anterior[k] : ENV.delete(k)
      end
    end

    # ----------------------------------------------------------------- assinatura

    test "base pública é partner_id + path + timestamp" do
      assert_equal "#{PARTNER_ID}/api/v2/auth/token/get1700000000",
                   @assinatura.base_string(path: "/api/v2/auth/token/get", timestamp: 1_700_000_000)
    end

    test "base com escopo de loja acrescenta access_token e shop_id, nessa ordem" do
      base = @assinatura.base_string(path: "/api/v2/payment/get_escrow_list", timestamp: 1_700_000_000,
                                     access_token: "AT123", shop_id: 55_667)

      assert_equal "#{PARTNER_ID}/api/v2/payment/get_escrow_list1700000000AT12355667", base
    end

    test "sign é o HMAC-SHA256 da base com a partner_key" do
      base = @assinatura.base_string(path: "/api/v2/payment/get_escrow_list", timestamp: 1_700_000_000,
                                     access_token: "AT123", shop_id: 55_667)

      assert_equal OpenSSL::HMAC.hexdigest("SHA256", PARTNER_KEY, base),
                   @assinatura.sign(path: "/api/v2/payment/get_escrow_list", timestamp: 1_700_000_000,
                                    access_token: "AT123", shop_id: 55_667)
    end

    test "assinatura é determinística e sensível a timestamp e escopo" do
      assert_equal @assinatura.sign(path: "/x", timestamp: 1), @assinatura.sign(path: "/x", timestamp: 1)
      refute_equal @assinatura.sign(path: "/x", timestamp: 1), @assinatura.sign(path: "/x", timestamp: 2)
      refute_equal @assinatura.sign(path: "/x", timestamp: 1),
                   @assinatura.sign(path: "/x", timestamp: 1, access_token: "AT", shop_id: 9)
    end

    test "query carrega o necessário e nunca a partner_key" do
      com_loja = @assinatura.query_for(path: "/api/v2/shop/get_shop_info", timestamp: 1_700_000_000,
                                       access_token: "AT", shop_id: 9)
      publica = @assinatura.query_for(path: "/api/v2/auth/token/get", timestamp: 1_700_000_000)

      assert_equal %i[access_token partner_id shop_id sign timestamp], com_loja.keys.sort
      assert_equal %i[partner_id sign timestamp], publica.keys.sort, "chamada pública não pode vazar token"
      assert com_loja.values.map(&:to_s).none? { |v| v.include?("chave-secreta") }
    end

    # ----------------------------------------------------------------------- host

    test "host segue a região, e SHOPEE_HOST sobrescreve" do
      assert_equal "https://openplatform.shopee.com.br", S::Settings.host

      com_env("SHOPEE_REGION" => "global") do
        assert_equal "https://partner.shopeemobile.com", S::Settings.host
      end

      com_env("SHOPEE_HOST" => "https://sandbox.exemplo") do
        assert_equal "https://sandbox.exemplo", S::Settings.host
      end
    end

    # ---------------------------------------------------------------- autorização

    test "URL de autorização carrega o state dentro do redirect" do
      tenant = criar_tenant
      resultado = S::Authorization.new(tenant: tenant, user: criar_usuario(tenant: tenant)).call

      url = URI.parse(resultado[:authorization_url])
      query = URI.decode_www_form(url.query).to_h

      assert url.to_s.start_with?("https://openplatform.shopee.com.br")
      assert_equal "/api/v2/shop/auth_partner", url.path
      assert %w[partner_id timestamp sign].all? { |k| query[k].present? }

      # A Shopee não tem parâmetro state: ele só volta se viajar no redirect_uri.
      redirect = URI.parse(query["redirect"])

      assert_equal resultado[:state], URI.decode_www_form(redirect.query).to_h["state"]
      assert_equal "/api/integracoes/shopee/callback", redirect.path
    end

    # -------------------------------------------------------------------- callback

    test "callback exige o shop_id, conecta a conta e cifra o token" do
      tenant = criar_tenant
      usuario = criar_usuario(tenant: tenant)
      falso = OauthFalso.new(expires_in: 14_400, prefixo: "S")

      resultado = S::Authorization.new(tenant: tenant, user: usuario).call
      credencial = S::Callback.new(code: "CODE-1", shop_id: "778899",
                                   state: resultado[:state], client: falso).call

      assert_equal [["CODE-1", "778899"]], falso.exchange_calls
      assert credencial.connected?
      assert_equal "778899", credencial.platform_account.external_id
      assert_equal "shopee", credencial.platform_account.platform
      # 4h, não 6h como o ML — a janela de renovação é mais apertada.
      assert_in_delta 14_400, credencial.expires_at - Time.current, 400

      bruto = ActiveRecord::Base.connection.select_value(
        "SELECT access_token FROM marketplace_credentials WHERE id = #{credencial.id}"
      ).to_s

      refute_includes bruto, "SAT-1"

      assert_raises(S::Callback::InvalidState, "state precisa ser de uso único") do
        S::Callback.new(code: "C", shop_id: "778899", state: resultado[:state], client: falso).call
      end

      outro = S::Authorization.new(tenant: tenant, user: usuario).call

      assert_raises(S::Callback::MissingShop) do
        S::Callback.new(code: "C", shop_id: nil, state: outro[:state], client: falso).call
      end
    end

    # ------------------------------------------------------------------- renovação

    test "renovação usa o shop_id da conta e a fábrica constrói o cliente certo" do
      tenant = criar_tenant
      falso = OauthFalso.new(expires_in: 14_400, prefixo: "S")
      resultado = S::Authorization.new(tenant: tenant, user: criar_usuario(tenant: tenant)).call
      credencial = S::Callback.new(code: "CODE-1", shop_id: "778899",
                                   state: resultado[:state], client: falso).call

      credencial.update_columns(expires_at: 2.minutes.from_now)

      token = Credentials::TokenProvider.new(
        platform_account: credencial.platform_account, client: falso
      ).access_token

      assert_equal "SAT-2", token
      assert_equal "SRT-2", credencial.reload.refresh_token

      cliente = Credentials::TokenProvider::OAUTH_CLIENTS["shopee"].call(credencial.platform_account)

      assert_kind_of S::OauthClient, cliente
    end

    # -------------------------------------------------------------------- provider

    test "provider está registrado e não sai para a rede em teste" do
      tenant = criar_tenant
      falso = OauthFalso.new(expires_in: 14_400, prefixo: "S")
      resultado = S::Authorization.new(tenant: tenant, user: criar_usuario(tenant: tenant)).call
      conta = S::Callback.new(code: "CODE-1", shop_id: "778899",
                              state: resultado[:state], client: falso).call.platform_account

      assert Ingestors::MarketplaceIngestor::PROVIDERS.key?("shopee")
      assert Providers::ShopeeProvider.configured?(conta)

      # A leitura financeira passou a existir (ver shopee_escrow_test). O que
      # este teste garante é que ela NÃO sai para a rede a partir da suíte.
      assert_raises(RedeExterna::Bloqueada) do
        Providers::ShopeeProvider.new(account: conta)
                                 .financial_events(start_date: Date.current - 1, end_date: Date.current)
      end
    end
  end
end
