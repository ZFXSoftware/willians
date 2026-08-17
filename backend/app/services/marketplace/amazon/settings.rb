module Marketplace
  module Amazon
    module Settings
      PLATFORM = "amazon".freeze

      # Endpoints da SP-API por região. O Brasil pertence à região NA.
      REGIONS = {
        "na" => "https://sellingpartnerapi-na.amazon.com",
        "eu" => "https://sellingpartnerapi-eu.amazon.com",
        "fe" => "https://sellingpartnerapi-fe.amazon.com"
      }.freeze

      DEFAULT_REGION = "na".freeze

      LWA_TOKEN_URL = "https://api.amazon.com/auth/o2/token".freeze

      # Tela de consentimento do vendedor. Varia por país; o padrão é o do
      # Brasil, já que é o mercado do cliente.
      DEFAULT_CONSENT_HOST = "https://sellercentral.amazon.com.br".freeze

      CONSENT_PATH = "/apps/authorize/consent".freeze

      CALLBACK_PATH = "/api/integracoes/amazon/callback".freeze

      RETURN_PATH = "/integracoes".freeze

      PATHS = {
        financial_events: "/finances/v0/financialEvents",
        financial_event_groups: "/finances/v0/financialEventGroups"
      }.freeze

      class MissingConfig < StandardError; end

      def self.configured?
        ENV["AMAZON_CLIENT_ID"].present? &&
          ENV["AMAZON_CLIENT_SECRET"].present? &&
          ENV["AMAZON_APP_ID"].present?
      end

      def self.client_id = ENV["AMAZON_CLIENT_ID"].presence

      def self.client_secret = ENV["AMAZON_CLIENT_SECRET"].presence

      def self.app_id = ENV["AMAZON_APP_ID"].presence

      # App recém-registrado no Seller Central nasce em rascunho, e nesse estado
      # a autorização exige `version=beta`. Ligue enquanto testa; desligue ao
      # publicar o app.
      def self.draft_app?
        %w[true 1].include?(ENV["AMAZON_APP_DRAFT"].to_s.strip.downcase)
      end

      def self.host
        ENV["AMAZON_HOST"].presence ||
          REGIONS.fetch(ENV["AMAZON_REGION"].presence || DEFAULT_REGION, REGIONS[DEFAULT_REGION])
      end

      def self.consent_url
        base = ENV["AMAZON_CONSENT_HOST"].presence || DEFAULT_CONSENT_HOST

        URI.join(base, CONSENT_PATH).to_s
      end

      def self.token_url
        ENV["AMAZON_LWA_TOKEN_URL"].presence || LWA_TOKEN_URL
      end

      def self.path(nome)
        PATHS.fetch(nome)
      end

      def self.redirect_uri
        ENV["AMAZON_REDIRECT_URI"].presence || build(CALLBACK_PATH)
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

        raise MissingConfig, "APP_PUBLIC_URL não configurado — a Amazon exige redirect fixo." if base.blank?

        URI.join(base, path).to_s
      end
    end
  end
end
