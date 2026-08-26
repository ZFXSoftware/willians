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

    # Categorias para valores sem vínculo com pedido ou nota (briefing 2.6).
    # Não têm padrão: são códigos do plano de contas de cada empresa, e chutar
    # um lançaria receita ou despesa na conta errada.
    TRANSITORIA_RECEITA_KEY = "omie_categoria_transitoria_receita".freeze

    TRANSITORIA_DESPESA_KEY = "omie_categoria_transitoria_despesa".freeze

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

    # direction: :credit (recebido) ou :debit (cobrado)
    def categoria_transitoria(direction)
      chave = direction.to_s == "credit" ? TRANSITORIA_RECEITA_KEY : TRANSITORIA_DESPESA_KEY

      valor = lookup(chave)

      raise MissingConfig, mensagem_transitoria(chave, direction) if valor.blank?

      valor.to_s
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

    # Do mais específico para o mais genérico.
    #
    # A tela de Configurações entra entre a conta e o metadata do tenant: ela é
    # a forma normal de configurar (por empresa), enquanto o metadata continua
    # servindo para ajuste por conta de marketplace e o ENV como padrão do
    # servidor. Sem este passo, preencher a tela não teria efeito nenhum sobre
    # os códigos do OMIE — que é como estava.
    def lookup(key)
      from_platform_account(key) ||
        from_configuracoes(key) ||
        from_tenant(key) ||
        from_env(key)
    end

    # A tela guarda a chave sem o prefixo `omie_`, que só existe no metadata.
    def from_configuracoes(key)
      return if tenant.blank?

      Integracoes::Config.do_banco("omie", key.to_s.delete_prefix("omie_"), tenant: tenant).presence
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

      return "configuracao" if from_configuracoes(key)

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

    # A mensagem manda para a TELA, e não mais para o metadata: dizer "grave em
    # metadata" a quem não tem acesso ao banco é não dizer nada.
    def onde_configurar(chave)
      campo = chave.to_s.delete_prefix("omie_")

      "Preencha em Configurações > OMIE (campo #{campo}), ou por conta de " \
      "marketplace em Integrações. Rode `./deploy/deploy.sh rake omie:opcoes` " \
      "para ver os códigos disponíveis no seu OMIE."
    end

    def mensagem_transitoria(chave, direction)
      tipo = direction.to_s == "credit" ? "receita (1.x)" : "despesa (2.x)"

      "#{chave} não configurado. É a categoria de #{tipo} onde entram os valores " \
        "sem vínculo com pedido ou nota fiscal. Escolha uma no plano de contas do " \
        "OMIE (ListarCategorias) e grave em platform_account.metadata ou " \
        "tenant.metadata, ou defina #{chave.upcase} no ambiente."
    end

    def missing_message(key)
      alvo =
        if platform_account
          "platform_account ##{platform_account.id} (#{platform_account.platform}) ou tenant ##{tenant&.id}"
        else
          "tenant ##{tenant&.id}"
        end

      "#{key} não configurado para #{alvo}. #{onde_configurar(key)}"
    end
  end
end
