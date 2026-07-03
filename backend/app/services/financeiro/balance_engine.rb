module Financeiro
  class BalanceEngine
    def initialize(
      tenant:,
      platform_account:
    )
      @tenant = tenant
      @platform_account = platform_account
    end

    def call
      {
        available_balance: available_balance,

        future_balance: future_balance,

        blocked_balance: blocked_balance,

        total_balance:
          available_balance +
          future_balance
      }
    end

    private

    attr_reader :tenant,
                :platform_account

    def available_balance
      settled_credits -
        settled_debits
    end

    def future_balance
      scheduled_receivables.sum(
        :net_amount
      )
    end

    def blocked_balance
      disputed_entries.sum(
        :amount
      )
    end

    def settled_credits
      FinancialEntry.where(
        tenant: tenant,
        platform_account: platform_account,
        direction: :credit,
        status: :settled
      ).sum(:amount)
    end

    def settled_debits
      FinancialEntry.where(
        tenant: tenant,
        platform_account: platform_account,
        direction: :debit,
        status: :settled
      ).sum(:amount)
    end

    def scheduled_receivables
      ReceivableUnit.where(
        tenant: tenant,
        platform_account: platform_account,
        status: [
          :scheduled,
          :available
        ]
      )
    end

    def disputed_entries
      FinancialEntry.where(
        tenant: tenant,
        platform_account: platform_account,
        status: :disputed
      )
    end
  end
end