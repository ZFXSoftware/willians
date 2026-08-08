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

      # ATENÇÃO: os caminhos abaixo NÃO foram confirmados na documentação
      # oficial — as páginas da Shopee exigem login de parceiro. A mecânica de
      # assinatura e transporte está verificada; estes caminhos são o que
      # precisa ser conferido no portal antes de ligar em produção, e cada um
      # pode ser corrigido por variável de ambiente.
      PATHS = {
        authorize: "/api/v2/shop/auth_partner",
        token: "/api/v2/auth/token/get",
        refresh: "/api/v2/auth/access_token/get",
        escrow_list: "/api/v2/payment/get_escrow_list",
        escrow_detail: "/api/v2/payment/get_escrow_detail",
        payout_detail: "/api/v2/payment/get_payout_detail",
        wallet_transactions: "/api/v2/payment/get_wallet_transaction_list"
      }.freeze

      CALLBACK_PATH = "/api/integracoes/shopee/callback".freeze

      RETURN_PATH = "/integracoes".freeze

      class MissingConfig < StandardError; end

      def self.configured?
        ENV["SHOPEE_PARTNER_ID"].present? && ENV["SHOPEE_PARTNER_KEY"].present?
      end

      def self.partner_id
        ENV["SHOPEE_PARTNER_ID"].presence
      end

      def self.partner_key
        ENV["SHOPEE_PARTNER_KEY"].presence
      end

      def self.host
        ENV["SHOPEE_HOST"].presence ||
          HOSTS.fetch(ENV["SHOPEE_REGION"].presence || DEFAULT_REGION, HOSTS[DEFAULT_REGION])
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
