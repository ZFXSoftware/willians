require "openssl"

module Marketplace
  module Shopee
    # Assinatura HMAC-SHA256 exigida em toda chamada da API v2 da Shopee.
    #
    # A base é a concatenação, NESTA ordem, sem separadores:
    #
    #   partner_id + caminho_da_api + timestamp [+ access_token + shop_id]
    #
    # access_token e shop_id entram apenas nas chamadas com escopo de loja.
    # Endpoints públicos (obter token, renovar token) assinam só os três
    # primeiros — incluir os outros dois ali invalida a assinatura.
    class Signature
      def initialize(partner_id:, partner_key:)
        @partner_id = partner_id

        @partner_key = partner_key
      end

      def base_string(path:, timestamp:, access_token: nil, shop_id: nil)
        "#{partner_id}#{path}#{timestamp}#{access_token}#{shop_id}"
      end

      def sign(path:, timestamp:, access_token: nil, shop_id: nil)
        OpenSSL::HMAC.hexdigest(
          "SHA256",
          partner_key.to_s,
          base_string(
            path: path,
            timestamp: timestamp,
            access_token: access_token,
            shop_id: shop_id
          )
        )
      end

      # Parâmetros que acompanham toda requisição, já assinados.
      def query_for(path:, timestamp: Time.current.to_i, access_token: nil, shop_id: nil)
        {
          partner_id: partner_id,
          timestamp: timestamp,
          sign: sign(
            path: path,
            timestamp: timestamp,
            access_token: access_token,
            shop_id: shop_id
          ),
          access_token: access_token,
          shop_id: shop_id
        }.compact
      end

      private

      attr_reader :partner_id,
                  :partner_key
    end
  end
end
