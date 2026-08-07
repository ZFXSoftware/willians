module Omie
  # Códigos do OMIE necessários para lançar títulos.
  #
  # Uma empresa no OMIE tem VÁRIOS clientes/fornecedores, várias contas
  # correntes e um plano de contas próprio — e cada marketplace normalmente
  # corresponde a um cliente e a uma conta diferentes. Por isso a resolução é
  # hierárquica, do mais específico para o mais genérico:
  #
  #   platform_account.metadata  ->  tenant.metadata  ->  ENV
  #
  # O ENV existe só como default de ambiente/desenvolvimento; em produção o
  # normal é cada conta de marketplace carregar os próprios códigos.
  class Settings
    class MissingConfig < StandardError; end

    CLIENTE_KEY = "omie_cliente_fornecedor_id".freeze

    CONTA_KEY = "omie_conta_corrente_id".freeze

    CATEGORIAS_KEY = "omie_categorias".freeze

    DEFAULT_CATEGORIES = {
      "sale" => "1.01.01",
      "fee" => "1.02.01",
      "refund" => "1.03.01"
    }.freeze

    FALLBACK_CATEGORY = "1.99.99".freeze

    def self.for(financial_entry)
      new(
        tenant: financial_entry.tenant,
        platform_account: financial_entry.platform_account
      )
    end

    def initialize(tenant:, platform_account: nil)
      @tenant = tenant

      @platform_account = platform_account
    end

    def cliente_fornecedor_id
      fetch_integer!(CLIENTE_KEY)
    end

    def conta_corrente_id
      fetch_integer!(CONTA_KEY)
    end

    # Plano de contas varia por cliente do OMIE — os defaults são só um ponto de
    # partida e devem ser sobrescritos por conta ou por tenant.
    def categoria_para(entry_type)
      configured = categorias[entry_type.to_s].presence

      configured || DEFAULT_CATEGORIES.fetch(entry_type.to_s, FALLBACK_CATEGORY)
    end

    def categorias
      value = lookup(CATEGORIAS_KEY)

      value.is_a?(Hash) ? value.stringify_keys : {}
    end

    # Diagnóstico: de onde veio cada valor (ou o que está faltando).
    def resolved
      {
        cliente_fornecedor_id: safe(CLIENTE_KEY),
        conta_corrente_id: safe(CONTA_KEY),
        origem_cliente: source_of(CLIENTE_KEY),
        origem_conta: source_of(CONTA_KEY),
        categorias: DEFAULT_CATEGORIES.keys.index_with { |type| categoria_para(type) }
      }
    end

    private

    attr_reader :tenant,
                :platform_account

    def lookup(key)
      from_platform_account(key) ||
        from_tenant(key) ||
        from_env(key)
    end

    def from_platform_account(key)
      platform_account&.metadata&.[](key).presence
    end

    def from_tenant(key)
      tenant&.metadata&.[](key).presence
    end

    def from_env(key)
      ENV[key.upcase].presence
    end

    def source_of(key)
      return "platform_account" if from_platform_account(key)

      return "tenant" if from_tenant(key)

      return "env" if from_env(key)

      "faltando"
    end

    def fetch_integer!(key)
      value = lookup(key)

      raise MissingConfig, missing_message(key) if value.blank?

      value.to_i
    end

    def safe(key)
      fetch_integer!(key)
    rescue MissingConfig
      nil
    end

    def missing_message(key)
      alvo =
        if platform_account
          "platform_account ##{platform_account.id} (#{platform_account.platform}) ou tenant ##{tenant&.id}"
        else
          "tenant ##{tenant&.id}"
        end

      "#{key} não configurado para #{alvo}, e #{key.upcase} não está no ambiente. " \
        "Obtenha o código no OMIE (ListarClientes / ListarContasCorrentes) e grave em metadata."
    end
  end
end
