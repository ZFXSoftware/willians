module Conciliacao
  # Orquestra a conciliação de todas as contas de marketplace no escopo pedido.
  #
  # Cada conta é isolada: uma falha de integração em uma delas não derruba as
  # demais, apenas entra no resumo como falha.
  class ConciliacaoService
    DEFAULT_WINDOW_DAYS = 30

    LOG_PREFIX = "[ConciliacaoService]".freeze

    def initialize(
      omie_client: nil,
      tenant: nil,
      platform_account: nil,
      start_date: nil,
      end_date: nil,
      sincronizar: true,
      forcar: false
    )
      @omie_client = omie_client

      @tenant = tenant

      @platform_account = platform_account

      @end_date = (end_date || Date.current).to_date

      @start_date =
        (start_date || @end_date - DEFAULT_WINDOW_DAYS).to_date

      @sincronizar = sincronizar

      @forcar = forcar
    end

    def processar
      # Buscar ANTES de conciliar. Conciliar é comparar o razão com o OMIE; se
      # ninguém trouxe os eventos do marketplace para o razão, a comparação é
      # entre o OMIE e o vazio — e sai como sucesso com zero lançamentos.
      sincronizacao = sincronizar!

      # Agrupado por empresa porque as credenciais do OMIE são dela: o
      # disparo agendado vem sem tenant e varre todo mundo de uma vez.
      grupos = platform_accounts.includes(:tenant).group_by(&:tenant)

      log "Conciliando #{grupos.values.sum(&:size)} conta(s) em #{grupos.size} empresa(s), " \
          "de #{start_date} a #{end_date}"

      simulacoes = []

      rotinas = {}

      resultados = grupos.flat_map do |empresa, contas|
        Current.with_tenant(empresa) do
          simulacoes << empresa.name unless credenciais_reais?

          # ANTES de conciliar: a conciliação compara o repasse com os títulos
          # do OMIE, e é esta rotina que põe os títulos lá. Conciliar primeiro
          # seria comparar com o que ainda não chegou.
          rotinas[empresa.id] = rotina_fiscal(empresa)

          # Uma leitura só do OMIE para todas as contas da empresa.
          totais = carregar_totais_omie(contas)

          contas.map { |conta| processar_conta(conta, totais) }
        end
      end

      {
        start_date: start_date,
        end_date: end_date,
        processed: resultados.count { |r| r[:status] == "completed" },
        failed: resultados.count { |r| r[:status] == "failed" },
        simulacao: simulacoes.any?,
        empresas_em_simulacao: simulacoes,
        sincronizacao: sincronizacao,
        rotina_fiscal: rotinas,
        runs: resultados
      }
    end

    private

    attr_reader :omie_client,
                :tenant,
                :platform_account,
                :start_date,
                :end_date,
                :sincronizar,
                :forcar

    # A ingestão nunca derruba a conciliação: se o marketplace estiver fora do
    # ar, o que já está no razão continua valendo a pena conferir.
    def sincronizar!
      return unless sincronizar

      Marketplace::SincronizacaoService.new(
        tenant: tenant,
        platform_account: platform_account,
        start_date: start_date,
        end_date: end_date,
        forcar: forcar
      ).call
    rescue StandardError => e
      Rails.logger.error "#{LOG_PREFIX} ingestão falhou por inteiro: #{e.class} #{e.message}"

      { erro: e.message }
    end

    # Trazer as notas do Tiny e levá-las ao OMIE é FUNÇÃO do sistema, não
    # migração de uma vez — então roda no ciclo, e não quando alguém lembra de
    # clicar. Nunca derruba a conciliação: sem títulos novos, o que já está lá
    # continua valendo a pena conferir.
    def rotina_fiscal(empresa)
      Fiscal::RotinaDeNotas.new(tenant: empresa).call
    rescue StandardError => e
      Rails.logger.error "#{LOG_PREFIX} rotina fiscal da empresa ##{empresa.id}: #{e.message}"

      { erro: e.message }
    end

    def platform_accounts
      return PlatformAccount.where(id: platform_account.id) if platform_account

      scope = PlatformAccount.where(status: :active)

      scope = scope.where(tenant: tenant) if tenant

      scope.where(tenant: Tenant.where(status: :active))
    end

    # Sem credencial do OMIE a conciliação roda contra o cliente de simulação —
    # útil em desenvolvimento, mas o resultado não vale como conferência.
    def credenciais_reais?
      omie_client.present? || Omie::Client.configured?
    end

    # Os títulos a receber são da empresa e não variam por conta de marketplace.
    # Buscá-los uma vez por conta faria requisições idênticas em sequência, e o
    # Omie responde a isso bloqueando por "consumo redundante".
    # Quanto tempo aceitamos esperar o desbloqueio do OMIE. Ele pede algo como 54
    # segundos; mais que dois minutos não é espera, é execução travada.
    ESPERA_MAXIMA = 120

    def carregar_totais_omie(contas)
      return if contas.empty?

      tentar_totais_omie
    rescue Omie::Client::RedundantConsumption => e
      # O OMIE DIZ quanto esperar, e a exceção já carrega esse número desde que
      # foi criada — só ninguém usava. Sem a espera, a conciliação desistia do
      # índice e cada conta repetia a MESMA requisição na hora, tomando o mesmo
      # bloqueio: a execução inteira falhava por um limite que passa em um minuto.
      espera = e.retry_after.to_i

      if espera.positive? && espera <= ESPERA_MAXIMA
        log "OMIE pediu #{espera}s antes de repetir ListarContasReceber. Esperando."

        esperar(espera + 1)

        return tentar_totais_omie
      end

      registrar_falha_de_totais(e)
    rescue StandardError => e
      registrar_falha_de_totais(e)
    end

    # Num método próprio para o teste poder observar a espera sem biblioteca de
    # mock: uma subclasse sobrescreve isto e registra os segundos.
    def esperar(segundos)
      sleep(segundos)
    end

    def tentar_totais_omie
      ConciliacaoEngine.carregar_totais(
        client: omie_client || (credenciais_reais? ? Omie::Client.new : Omie::FakeOmieClient.new),
        start_date: start_date,
        end_date: end_date
      )
    end

    # Sem o índice, cada conta tenta por conta própria e reporta o erro dela.
    def registrar_falha_de_totais(erro)
      Rails.logger.warn "#{LOG_PREFIX} não consegui carregar os títulos de uma vez: #{erro.class} #{erro.message}"

      nil
    end

    def processar_conta(conta, totais = nil)
      run = build_engine(conta, totais).call

      log "Conta #{conta.id} (#{conta.platform}): #{run.matches_found} match(es), #{run.divergences_found} divergência(s)"

      {
        platform_account_id: conta.id,
        platform: conta.platform,
        status: run.status,
        conciliation_run_id: run.id,
        total_entries: run.total_entries,
        matches: run.matches_found,
        divergences: run.divergences_found
      }
    rescue StandardError => e
      Rails.logger.error "#{LOG_PREFIX} Falha na conta #{conta.id}: #{e.class} #{e.message}"

      {
        platform_account_id: conta.id,
        platform: conta.platform,
        status: "failed",
        error: e.message
      }
    end

    def build_engine(conta, totais = nil)
      ConciliacaoEngine.new(
        tenant: conta.tenant,

        platform_account: conta,

        start_date: start_date,

        end_date: end_date,

        omie_client: omie_client,

        omie_totals: totais
      )
    end

    def log(message)
      Rails.logger.info "#{LOG_PREFIX} #{message}"
    end
  end
end
