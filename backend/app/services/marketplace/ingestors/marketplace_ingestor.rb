module Marketplace
  module Ingestors
    class MarketplaceIngestor
      PROVIDERS = {
        mercado_livre:
          Marketplace::Providers::MercadoLivreProvider
      }.freeze

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
        financial_events.each do |event|
          persist_event!(event)
        end
      end

      private

      attr_reader :tenant,
                  :platform_account,
                  :start_date,
                  :end_date

      def provider
        provider_class.new(
          account: platform_account
        )
      end

      def provider_class
        PROVIDERS.fetch(
          platform_account.provider.to_sym
        )
      end

      def financial_events
        provider.financial_events(
          start_date: start_date,
          end_date: end_date
        )
      end

      def persist_event!(event)
        FinancialEntry.create!(
          tenant: tenant,

          platform_account: platform_account,

          external_id: event[:external_id],

          source: event[:source],

          entry_type: event[:entry_type],

          direction: event[:direction],

          amount: event[:amount],

          occurred_at: event[:occurred_at],

          available_on: event[:available_on],

          raw_payload: event[:raw_payload],

          status: :pending
        )
      rescue ActiveRecord::RecordNotUnique
        nil
      end
    end
  end
end