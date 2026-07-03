module Conciliacao
  class ConciliacaoEngine
    def initialize(
      tenant:,
      platform_account:,
      start_date:,
      end_date:
    )
      @tenant = tenant
      @platform_account = platform_account
      @start_date = start_date
      @end_date = end_date
    end

    def call
      create_run!

      reconcile_payouts!

      finalize_run!
    rescue => e
      fail_run!(e)

      raise
    end

    private

    attr_reader :tenant,
                :platform_account,
                :start_date,
                :end_date,
                :run

    def create_run!
      @run = ConciliationRun.create!(
        tenant: tenant,
        platform_account: platform_account,

        status: :processing,

        started_at: Time.current
      )
    end

    def reconcile_payouts!
      payouts.find_each do |payout|
        reconcile_payout!(payout)
      end
    end

    def reconcile_payout!(payout)
      omie_total =
        fetch_omie_total(payout)

      internal_total =
        payout.net_amount

      difference =
        internal_total - omie_total

      ConciliacaoRegistro.create!(
        tenant: tenant,

        conciliation_run: run,

        payout_batch: payout,

        status: difference.zero? ? :matched : :divergent,

        match_type: :exact,

        confidence_score:
          difference.zero? ? 100 : 0,

        valor_marketplace: internal_total,

        valor_omie: omie_total,

        diferenca: difference,

        conciliated_at: Time.current
      )
    end

    def payouts
      PayoutBatch.where(
        tenant: tenant,
        platform_account: platform_account
      ).where(
        paid_at: start_date..end_date
      )
    end

    def fetch_omie_total(_payout)
      0
    end

    def finalize_run!
      run.update!(
        status: :completed,
        finished_at: Time.current
      )
    end

    def fail_run!(error)
      run&.update!(
        status: :failed,
        metadata: {
          error: error.message
        }
      )
    end
  end
end