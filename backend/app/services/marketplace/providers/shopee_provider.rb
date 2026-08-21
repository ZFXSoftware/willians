module Marketplace
  module Providers
    # A autenticação da Shopee está pronta e verificada (assinatura HMAC,
    # autorização de loja, renovação de token). A LEITURA FINANCEIRA não está.
    #
    # Os caminhos de payment (escrow, payout, wallet) não puderam ser conferidos
    # na documentação oficial — o portal da Shopee exige login de parceiro. Em
    # vez de inventar nomes de campo e produzir lançamentos errados no razão,
    # esta chamada falha dizendo exatamente o que falta.
    #
    # Para implementar, o que precisa ser confirmado no portal:
    #   - caminho e parâmetros de get_escrow_list / get_payout_detail
    #   - formato da resposta: nomes dos campos de valor, taxa, pedido e data
    #   - se o repasse traz o número da nota fiscal (é a nossa chave de
    #     conciliação, ver Omie::Readers::ReceivableTotals)
    class ShopeeProvider < BaseProvider
      class NotImplemented < StandardError; end

      def financial_events(start_date:, end_date:)
        raise NotImplemented,
              "Leitura financeira da Shopee não implementada. A conexão da loja funciona e " \
              "os endpoints existem (#{Shopee::Settings.path(:escrow_detail)}, " \
              "#{Shopee::Settings.path(:payout_detail)}), mas o formato de requisição e " \
              "resposta ainda não foi confirmado — implementar às cegas produziria valores " \
              "errados na contabilidade. Use MARKETPLACE_SIMULATION=true em desenvolvimento."
      end

      private

      def client
        @client ||= Shopee::Client.new(
          access_token: access_token,
          shop_id: account.external_id
        )
      end
    end
  end
end
