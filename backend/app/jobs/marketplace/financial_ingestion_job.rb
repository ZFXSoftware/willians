module Marketplace
  class FinancialIngestionJob < ApplicationJob
    queue_as :default

    def perform(
      tenant_id,
      platform_account_id,
      start_date,
      end_date
    )
      tenant =
        Tenant.find(tenant_id)

      platform_account =
        PlatformAccount.find(platform_account_id)

      Marketplace::Ingestors::MarketplaceIngestor
        .new(
          tenant: tenant,
          platform_account: platform_account,
          start_date: start_date,
          end_date: end_date
        )
        .call
    end
  end
end