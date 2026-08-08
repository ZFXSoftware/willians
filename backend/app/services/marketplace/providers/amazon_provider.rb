module Marketplace
  module Providers
    # Único dos três marketplaces com leitura financeira implementada de fato: a
    # Amazon publica o modelo da SP-API abertamente, então os caminhos, os
    # parâmetros e a forma dos eventos puderam ser conferidos.
    #
    # Cuidado conhecido da própria documentação: pedidos das últimas 48 horas
    # podem ainda não aparecer nos eventos financeiros. Como a ingestão é
    # idempotente, o que faltar entra numa execução seguinte.
    class AmazonProvider < BaseProvider
      def financial_events(start_date:, end_date:)
        Amazon::FinancialEvents
          .new(client: client)
          .call(
            start_date: start_date,
            end_date: end_date
          )
      end

      private

      def client
        @client ||= Amazon::Client.new(access_token: access_token)
      end
    end
  end
end
