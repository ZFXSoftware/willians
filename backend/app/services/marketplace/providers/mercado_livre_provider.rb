module Marketplace
  module Providers
    class MercadoLivreProvider < BaseProvider
      def financial_events(
        start_date:,
        end_date:
      )
        response =
          client.get(
            "/financial/events",
            {
              start_date: start_date,
              end_date: end_date
            }
          )

        response.map do |event|
          normalize_event(event)
        end
      end

      private

      def client
        @client ||= MercadoLivreClient.new(
          access_token: account.access_token
        )
      end

      def normalize_event(event)
        Marketplace::Normalizers::FinancialEntryNormalizer
          .new(
            source: :mercado_livre,
            payload: event
          )
          .call
      end
    end
  end
end