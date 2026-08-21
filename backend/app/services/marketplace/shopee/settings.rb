module Marketplace
  module Shopee
    module Settings
      PLATFORM = "shopee".freeze

      # A Shopee tem host por região. O cliente é brasileiro, então o padrão é
      # o host do Brasil; `SHOPEE_HOST` sobrescreve (sandbox, outra região).
      HOSTS = {
        "br" => "https://openplatform.shopee.com.br",
        "global" => "https://partner.shopeemobile.com",
        "cn" => "https://openplatform.shopee.cn"
      }.freeze

      DEFAULT_REGION = "br".freeze

      # Os NOMES destes endpoints foram conferidos contra o índice da API v2 da
      # Shopee (referência lida em 2026-08-21): todos existem, nas categorias
      # Public, Payment, Order e Returns.
      #
      # O que continua NÃO confirmado é o formato de requisição e resposta de
      # cada um — o índice lista os nomes, não os parâmetros. É por isso que
      # `ShopeeProvider#financial_events` ainda levanta NotImplemented em vez de
      # inventar campos.
      #
      # Cada caminho é sobrescrevível por SHOPEE_PATH_<NOME>, para corrigir sem
      # deploy caso o prefixo difira.
      PATHS = {
        authorize: "/api/v2/shop/auth_partner",
        token: "/api/v2/auth/token/get",
        refresh: "/api/v2/auth/access_token/get",

        # --- dinheiro -------------------------------------------------------
        # get_escrow_detail é o que traz a quebra por pedido (bruto, taxas,
        # líquido); get_payout_detail é o saque para o banco.
        escrow_list: "/api/v2/payment/get_escrow_list",
        escrow_detail: "/api/v2/payment/get_escrow_detail",
        escrow_detail_batch: "/api/v2/payment/get_escrow_detail_batch",
        payout_detail: "/api/v2/payment/get_payout_detail",
        payout_info: "/api/v2/payment/get_payout_info",
        billing_transaction_info: "/api/v2/payment/get_billing_transaction_info",
        wallet_transactions: "/api/v2/payment/get_wallet_transaction_list",

        # Relatório de rendimentos: geração assíncrona, como o do Mercado Pago.
        gerar_extrato: "/api/v2/payment/generate_income_statement",
        extrato: "/api/v2/payment/get_income_statement",

        # --- pedidos e devoluções (briefing 2.8) ----------------------------
        order_list: "/api/v2/order/get_order_list",
        order_detail: "/api/v2/order/get_order_detail",
        return_list: "/api/v2/returns/get_return_list",
        return_detail: "/api/v2/returns/get_return_detail"
      }.freeze

      CALLBACK_PATH = "/api/integracoes/shopee/callback".freeze

      RETURN_PATH = "/integracoes".freeze

      class MissingConfig < StandardError; end

      def self.configured?(tenant: Current.tenant)
        Integracoes::Config.configurado?(PLATFORM, tenant: tenant)
      end

      def self.partner_id(tenant: Current.tenant)
        Integracoes::Config.get(PLATFORM, :partner_id, tenant: tenant)
      end

      def self.partner_key(tenant: Current.tenant)
        Integracoes::Config.get(PLATFORM, :partner_key, tenant: tenant)
      end

      def self.region(tenant: Current.tenant)
        Integracoes::Config.get(PLATFORM, :region, tenant: tenant) || DEFAULT_REGION
      end

      # SHOPEE_HOST continua fora da tela: é escape para sandbox, não credencial.
      def self.host(tenant: Current.tenant)
        ENV["SHOPEE_HOST"].presence || HOSTS.fetch(region(tenant: tenant), HOSTS[DEFAULT_REGION])
      end

      def self.path(nome)
        ENV["SHOPEE_PATH_#{nome.to_s.upcase}"].presence || PATHS.fetch(nome)
      end

      def self.redirect_uri
        ENV["SHOPEE_REDIRECT_URI"].presence || build(CALLBACK_PATH)
      end

      def self.return_url(status:, message: nil)
        uri = URI.parse(build(RETURN_PATH))

        uri.query = URI.encode_www_form(
          { integracao: PLATFORM, status: status, mensagem: message }.compact
        )

        uri.to_s
      end

      def self.build(path)
        base = ENV["APP_PUBLIC_URL"].presence

        if base.blank?
          raise MissingConfig,
                "APP_PUBLIC_URL não configurado. A autorização da Shopee exige uma URL " \
                "pública fixa para o retorno."
        end

        URI.join(base, path).to_s
      end
    end
  end
end
