module Marketplace
  module Providers
    # Leitura financeira da Shopee pelo escrow: cada pedido liquidado no
    # período vira uma venda pelo bruto e uma dedução para cada taxa.
    #
    # Endpoints e campos conferidos na referência da API v2 (2026-08-21):
    # get_escrow_list para descobrir o que foi liberado, get_escrow_detail para
    # a quebra. Ver Shopee::EscrowReader e Shopee::EscrowEvents.
    #
    # O saque para o banco e os ajustes fora de pedido vêm da CARTEIRA
    # (get_wallet_transaction_list, "only applicable for local shops" — que é o
    # caso do cliente). O get_payout_detail existe mas é só para vendedor
    # cross-border, então não serve aqui.
    #
    # As duas fontes se completam sem se sobrepor: a carteira descarta o
    # ESCROW_VERIFIED_ADD, que é o mesmo dinheiro que o escrow já decompôs em
    # venda e taxas. Ver Shopee::WalletEvents.
    class ShopeeProvider < BaseProvider
      class NotImplemented < StandardError; end

      # Pedidos cuja decomposição não fechou com o escrow_amount informado pela
      # Shopee. Ficam de fora do razão de propósito — ver EscrowReader.
      attr_reader :divergentes,
                  :falhas,
                  :saldo

      def financial_events(start_date:, end_date:)
        escrow = leitor.call(start_date: start_date, end_date: end_date)

        @divergentes = escrow.divergentes

        @falhas = escrow.falhas

        avisar(escrow)

        carteira = wallet.call(start_date: start_date, end_date: end_date)

        @saldo = carteira.saldo

        avisar_carteira(carteira)

        escrow.eventos + carteira.eventos
      end

      # Briefing 2.8: as devoluções como a Shopee as registra, com motivo,
      # estado da negociação e o pedido de origem.
      def returns(start_date:, end_date:)
        Shopee::ReturnReader.new(client: client).call(start_date: start_date, end_date: end_date)
      end

      # Briefing 2.4: o saldo que a Shopee declara, para o espelho.
      def account_balance(start_date:, end_date:)
        carteira = wallet.call(start_date: start_date, end_date: end_date)

        saldo = carteira.saldo

        return if saldo.blank?

        {
          available: saldo[:valor],
          future: nil,
          total: saldo[:valor],
          source: "carteira_shopee"
        }
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

      def avisar_carteira(resultado)
        if resultado.ignorados.any?
          Rails.logger.warn "[Shopee] tipos de movimentação não tratados: #{resultado.ignorados.inspect}"
        end

        return if resultado.pendentes.zero?

        Rails.logger.info "[Shopee] #{resultado.pendentes} movimentação(ões) ainda não concluída(s), ignoradas"
      end

      def leitor
        @leitor ||= Shopee::EscrowReader.new(client: client)
      end

      def wallet
        @wallet ||= Shopee::WalletReader.new(client: client)
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
