module Marketplace
  module Shopee
    # Retorno da autorização da loja.
    #
    # A Shopee devolve `code` e `shop_id` na query, e o `state` que embutimos na
    # redirect_uri. Como o endpoint é público, é o state — de uso único — que
    # amarra a autorização ao tenant certo.
    class Callback
      class InvalidState < StandardError; end

      class MissingShop < StandardError; end

      def initialize(code:, shop_id:, state:, client: nil)
        @code = code

        @shop_id = shop_id

        @state = state

        @client = client || OauthClient.new
      end

      def call
        raise MissingShop, "A Shopee não informou o shop_id no retorno" if shop_id.blank?

        oauth_state = OauthState.consume!(state)

        raise InvalidState, "State inválido, expirado ou já utilizado" if oauth_state.blank?

        raise InvalidState, "State de outra plataforma" unless oauth_state.platform == Settings::PLATFORM

        tokens = client.exchange_code(code: code, shop_id: shop_id)

        ActiveRecord::Base.transaction do
          conta = resolve_account!(oauth_state)

          persist_credential!(oauth_state, conta, tokens)
        end
      end

      private

      attr_reader :code,
                  :shop_id,
                  :state,
                  :client

      # O identificador da conta é o shop_id da Shopee.
      def resolve_account!(oauth_state)
        return oauth_state.platform_account if oauth_state.platform_account

        PlatformAccount.find_or_create_by!(
          tenant_id: oauth_state.tenant_id,
          platform: Settings::PLATFORM,
          external_id: shop_id.to_s
        ) do |conta|
          conta.name = "Shopee #{shop_id}"
          conta.status = :active
        end
      end

      def persist_credential!(oauth_state, conta, tokens)
        credencial = MarketplaceCredential.find_or_initialize_by(platform_account_id: conta.id)

        credencial.assign_attributes(
          tenant_id: oauth_state.tenant_id,

          platform: Settings::PLATFORM,

          access_token: tokens[:access_token],

          refresh_token: tokens[:refresh_token],

          expires_at: tokens[:expires_in].to_i.seconds.from_now,

          external_user_id: shop_id.to_s,

          status: :connected,

          last_refreshed_at: Time.current,

          refresh_failed_at: nil,

          refresh_error: nil,

          metadata: credencial.metadata.merge(
            "authorized_by_user_id" => oauth_state.user_id,
            "authorized_at" => Time.current,
            "shop_id" => shop_id.to_s
          )
        )

        credencial.save!

        credencial
      end
    end
  end
end
