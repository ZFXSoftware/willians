module Financeiro
  class BalanceSnapshotEngine
    def initialize(
      tenant:,
      platform_account:
    )
      @tenant = tenant
      @platform_account = platform_account
    end

    def call
      balances =
        BalanceEngine.new(
          tenant: tenant,
          platform_account: platform_account
        ).call

      PlatformBalanceSnapshot.create!(
        tenant: tenant,

        platform_account: platform_account,

        snapshot_date: Date.current,

        available_balance:
          balances[:available_balance],

        future_balance:
          balances[:future_balance],

        blocked_balance:
          balances[:blocked_balance],

        metadata: {
          generated_at: Time.current
        }
      )
    end

    private

    attr_reader :tenant,
                :platform_account
  end
end