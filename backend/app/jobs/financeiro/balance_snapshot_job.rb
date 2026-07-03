module Financeiro
  class BalanceSnapshotJob < ApplicationJob
    queue_as :default

    def perform(
      tenant_id,
      platform_account_id
    )
      tenant =
        Tenant.find(tenant_id)

      platform_account =
        PlatformAccount.find(
          platform_account_id
        )

      BalanceSnapshotEngine
        .new(
          tenant: tenant,
          platform_account: platform_account
        )
        .call
    end
  end
end