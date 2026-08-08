module Marketplace
  module Shopee
    # Autorização de loja da Shopee.
    #
    # Diferença relevante em relação ao Mercado Livre: a Shopee NÃO tem
    # parâmetro `state`. Ela só devolve `code` e `shop_id` para a URL de
    # redirect. Por isso o nosso state viaja dentro da própria redirect_uri —
    # sem ele o callback não teria como saber de qual tenant é a autorização.
    #
    # O access_token dura 4 horas e o refresh_token 30 dias. É bem mais curto
    # que o Mercado Livre (6 meses), então uma loja parada por um mês perde o
    # acesso e precisa reautorizar.
    class OauthClient
      ACCESS_TOKEN_TTL = 4.hours

      def initialize(shop_id: nil)
        @shop_id = shop_id
      end

      def self.configured?
        Settings.configured?
      end

      def authorization_url(state:, redirect_uri:)
        path = Settings.path(:authorize)

        uri = URI.join(Settings.host, path)

        uri.query = URI.encode_www_form(
          signature.query_for(path: path).merge(
            redirect: redirect_com_state(redirect_uri, state)
          )
        )

        uri.to_s
      end

      def exchange_code(code:, shop_id:)
        normalize(
          public_client.post_public(
            :token,
            code: code,
            shop_id: shop_id.to_i,
            partner_id: Settings.partner_id.to_i
          ),
          shop_id
        )
      end

      def refresh(refresh_token:)
        raise Client::Error, "shop_id é obrigatório para renovar o token da Shopee" if shop_id.blank?

        normalize(
          public_client.post_public(
            :refresh,
            refresh_token: refresh_token,
            shop_id: shop_id.to_i,
            partner_id: Settings.partner_id.to_i
          ),
          shop_id
        )
      end

      private

      attr_reader :shop_id

      def signature
        @signature ||= Signature.new(
          partner_id: Settings.partner_id,
          partner_key: Settings.partner_key
        )
      end

      def public_client
        @public_client ||= Client.new
      end

      # A Shopee exige que a redirect_uri registrada bata com a enviada; o
      # state entra como query, que é o que ela preserva no retorno.
      def redirect_com_state(redirect_uri, state)
        uri = URI.parse(redirect_uri)

        existentes = URI.decode_www_form(uri.query.to_s)

        uri.query = URI.encode_www_form(existentes + [["state", state]])

        uri.to_s
      end

      # Devolve no mesmo formato do OauthClient do Mercado Livre, para que o
      # TokenProvider trate as duas plataformas igual.
      def normalize(resposta, shop_id)
        {
          access_token: resposta["access_token"],
          refresh_token: resposta["refresh_token"],
          expires_in: (resposta["expire_in"] || ACCESS_TOKEN_TTL.to_i).to_i,
          scope: nil,
          user_id: shop_id,
          token_type: "shopee"
        }
      end
    end
  end
end
