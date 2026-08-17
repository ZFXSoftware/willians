module Fiscal
  module Tiny
    # O Tiny (hoje Olist ERP) é quem emite as NF-e das vendas de marketplace.
    # É dele que sai o elo `pedido do marketplace -> nota fiscal`, que não
    # existe do lado do Omie.
    module Settings
      V2_BASE = "https://api.tiny.com.br/api2".freeze

      V3_BASE = "https://api.tiny.com.br/public-api/v3".freeze

      DEFAULT_VERSION = "v2".freeze

      VERSIONS = %w[v2 v3].freeze

      class MissingConfig < StandardError; end

      def self.version
        v = ENV["TINY_API_VERSION"].presence || DEFAULT_VERSION

        return v if VERSIONS.include?(v)

        raise MissingConfig, "TINY_API_VERSION inválida: #{v}. Use #{VERSIONS.join(' ou ')}."
      end

      def self.token
        ENV["TINY_TOKEN"].presence
      end

      def self.configured?
        token.present?
      end

      def self.v2_base = ENV["TINY_V2_URL"].presence || V2_BASE

      def self.v3_base = ENV["TINY_V3_URL"].presence || V3_BASE

      def self.ensure_configured!
        return if configured?

        raise MissingConfig,
              "TINY_TOKEN não configurado. No Tiny: Início > Extensões da Olist > " \
              "instale 'Token API' (seção Vendas); depois Configurações > aba " \
              "E-commerce > Token API. Preencha TINY_TOKEN no .env."
      end
    end
  end
end
