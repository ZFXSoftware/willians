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
      end_date: nil
    )
      @omie_client = omie_client

      @tenant = tenant

      @platform_account = platform_account

      @end_date = (end_date || Date.current).to_date

      @start_date =
        (start_date || @end_date - DEFAULT_WINDOW_DAYS).to_date
    end

    def processar
      contas = platform_accounts.to_a

      log "Conciliando #{contas.size} conta(s) de #{start_date} a #{end_date}"

      resultados = contas.map { |conta| processar_conta(conta) }

      {
        start_date: start_date,
        end_date: end_date,
        processed: resultados.count { |r| r[:status] == "completed" },
        failed: resultados.count { |r| r[:status] == "failed" },
        runs: resultados
      }
    end

    private

    attr_reader :omie_client,
                :tenant,
                :platform_account,
                :start_date,
                :end_date

    def platform_accounts
      return PlatformAccount.where(id: platform_account.id) if platform_account

      scope = PlatformAccount.where(status: :active)

      scope = scope.where(tenant: tenant) if tenant

      scope.where(tenant: Tenant.where(status: :active))
    end

    def processar_conta(conta)
      run = build_engine(conta).call

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

    def build_engine(conta)
      ConciliacaoEngine.new(
        tenant: conta.tenant,

        platform_account: conta,

        start_date: start_date,

        end_date: end_date,

        omie_client: omie_client
      )
    end

    def log(message)
      Rails.logger.info "#{LOG_PREFIX} #{message}"
    end
  end
end
