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

      PROVEDOR = "tiny".freeze

      def self.token(tenant: Current.tenant)
        Integracoes::Config.get(PROVEDOR, :token, tenant: tenant)
      end

      def self.configured?(tenant: Current.tenant)
        token(tenant: tenant).present?
      end

      def self.v2_base = ENV["TINY_V2_URL"].presence || V2_BASE

      def self.v3_base = ENV["TINY_V3_URL"].presence || V3_BASE

      def self.ensure_configured!
        return if configured?

        raise MissingConfig,
              "Token do Tiny não configurado. No Tiny: Início > Extensões da Olist > " \
              "instale 'Token API' (seção Vendas); depois Configurações > aba " \
              "E-commerce > Token API. Cole o token em Integrações → Configurações."
      end
    end
  end
end
