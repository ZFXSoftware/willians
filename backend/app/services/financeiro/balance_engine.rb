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
      settled_by_direction["credit"] -
        settled_by_direction["debit"]
    end

    def future_balance
      scheduled_receivables.sum(:net_amount)
    end

    def blocked_balance
      entries.where(status: :disputed).sum(:amount)
    end

    # Uma única varredura agrupada em vez de um SUM por direção.
    def settled_by_direction
      @settled_by_direction ||=
        entries
          .where(status: :settled)
          .group(:direction)
          .sum(:amount)
          .tap { |totals| totals.default = BigDecimal("0") }
    end

    def entries
      FinancialEntry.where(
        tenant: tenant,
        platform_account: platform_account
      )
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
  end
end
