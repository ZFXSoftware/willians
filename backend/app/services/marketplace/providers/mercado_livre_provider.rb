module Marketplace
  module Providers
    class MercadoLivreProvider < BaseProvider
      SOURCE = :mercado_livre

      def financial_events(start_date:, end_date:)
        client
          .financial_events(
            start_date: start_date,
            end_date: end_date
          )
          .map { |event| normalize(SOURCE, event) }
      end

      private

      def client
        @client ||= Marketplace::Clients::MercadoLivreClient.new(
          access_token: access_token
        )
      end
    end
  end
end
