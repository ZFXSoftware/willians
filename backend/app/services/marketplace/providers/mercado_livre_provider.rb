module Marketplace
  module Providers
    # Traz do Mercado Livre os encargos e bonificações de faturamento.
    #
    # COBERTURA PARCIAL: esta é a visão de FATURAMENTO (o que o ML cobra do
    # vendedor — comissão de venda, Mercado Envios, Product Ads) e vem agregada
    # por período mensal, sem vínculo com o pedido.
    #
    # Ainda NÃO cobre os repasses (o dinheiro liberado ao vendedor) nem o detalhe
    # por venda. Enquanto isso não existir, os recebíveis continuam sendo
    # projetados a partir dos lançamentos de venda que chegarem por outra via.
    class MercadoLivreProvider < BaseProvider
      def financial_events(start_date:, end_date:)
        MercadoLivre::BillingEvents
          .new(client: billing_client)
          .call(
            start_date: start_date,
            end_date: end_date
          )
      end

      private

      def billing_client
        @billing_client ||= MercadoLivre::BillingClient.new(
          access_token: access_token
        )
      end
    end
  end
end
