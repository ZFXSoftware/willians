module Marketplace
  module Providers
    # Leitura financeira da Shopee pelo escrow: cada pedido liquidado no
    # período vira uma venda pelo bruto e uma dedução para cada taxa.
    #
    # Endpoints e campos conferidos na referência da API v2 (2026-08-21):
    # get_escrow_list para descobrir o que foi liberado, get_escrow_detail para
    # a quebra. Ver Shopee::EscrowReader e Shopee::EscrowEvents.
    #
    # AINDA FALTA o saque para o banco (o repasse propriamente dito). O
    # get_payout_detail existe, mas a própria documentação diz que é "applicable
    # for Cross Border (CB) sellers only" — o cliente é vendedor local
    # brasileiro, então aquele endpoint recusaria. A fonte para vendedor local
    # deve ser get_wallet_transaction_list ou get_payout_info, ainda não
    # confirmadas.
    class ShopeeProvider < BaseProvider
      class NotImplemented < StandardError; end

      # Pedidos cuja decomposição não fechou com o escrow_amount informado pela
      # Shopee. Ficam de fora do razão de propósito — ver EscrowReader.
      attr_reader :divergentes,
                  :falhas

      def financial_events(start_date:, end_date:)
        resultado = leitor.call(start_date: start_date, end_date: end_date)

        @divergentes = resultado.divergentes

        @falhas = resultado.falhas

        avisar(resultado)

        resultado.eventos
      end

      private

      def avisar(resultado)
        if resultado.divergentes.any?
          Rails.logger.warn(
            "[Shopee] #{resultado.divergentes.size} de #{resultado.pedidos} pedido(s) não " \
            "fecharam com o escrow_amount e foram DESCARTADOS: " \
            "#{resultado.divergentes.first(5).map { |d| "#{d[:order_sn]} (#{d[:diferenca]})" }.join(', ')}"
          )
        end

        return if resultado.falhas.empty?

        Rails.logger.warn "[Shopee] #{resultado.falhas.size} pedido(s) falharam na leitura do detalhe"
      end

      def leitor
        @leitor ||= Shopee::EscrowReader.new(client: client)
      end

      def client
        @client ||= Shopee::Client.new(
          access_token: access_token,
          shop_id: account.external_id
        )
      end
    end
  end
end
