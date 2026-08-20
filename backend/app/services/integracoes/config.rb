module Integracoes
  # Resolve o valor de um campo de integração: primeiro o que o usuário gravou
  # na tela de configurações (por tenant), depois o ambiente.
  #
  # O ambiente continua valendo como fallback de propósito: é o que mantém o
  # desenvolvimento e o deploy atual funcionando sem ninguém preencher tela, e
  # é onde ficam as credenciais de instalação quando não há um tenant no
  # contexto (jobs de manutenção, por exemplo).
  module Config
    VERDADEIROS = %w[true 1 sim].freeze

    def self.get(provedor, chave, tenant: Current.tenant)
      campo = Catalogo.campo_de!(provedor, chave)

      do_banco(provedor, chave, tenant: tenant).presence ||
        ENV[campo.env].presence ||
        campo.padrao
    end

    def self.bool(provedor, chave, tenant: Current.tenant)
      VERDADEIROS.include?(get(provedor, chave, tenant: tenant).to_s.strip.downcase)
    end

    # Todos os campos obrigatórios preenchidos?
    def self.configurado?(provedor, tenant: Current.tenant)
      Catalogo.campos(provedor)
              .select(&:obrigatorio?)
              .all? { |campo| get(provedor, campo.chave, tenant: tenant).present? }
    end

    def self.origem(provedor, chave, tenant: Current.tenant)
      campo = Catalogo.campo_de!(provedor, chave)

      return "configuracao" if do_banco(provedor, chave, tenant: tenant).present?

      return "ambiente" if ENV[campo.env].present?

      campo.padrao.present? ? "padrao" : "faltando"
    end

    def self.do_banco(provedor, chave, tenant: Current.tenant)
      return if tenant.blank?

      cache(tenant, provedor)[chave.to_s]
    end

    # Uma consulta por provedor por requisição, e não uma por campo.
    def self.cache(tenant, provedor)
      chave = [tenant.id, provedor.to_s]

      Current.settings_cache[chave] ||= IntegrationSetting.valores(tenant, provedor)
    end

    def self.limpar_cache(tenant = nil, provedor = nil)
      return Current.integration_settings = nil if tenant.nil?

      Current.settings_cache.delete([tenant.id, provedor.to_s])
    end
  end
end
