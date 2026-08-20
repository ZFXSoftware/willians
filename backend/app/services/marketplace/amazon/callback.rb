module Marketplace
  module Amazon
    # Retorno do consentimento no Seller Central.
    #
    # A Amazon devolve `spapi_oauth_code`, `state` e `selling_partner_id`. O
    # refresh token obtido na troca não expira por tempo — vale até o vendedor
    # revogar o acesso do app.
    class Callback
      class InvalidState < StandardError; end

      class MissingSeller < StandardError; end

      def initialize(code:, selling_partner_id:, state:, client: nil)
        @code = code

        @selling_partner_id = selling_partner_id

        @state = state

        @client = client || OauthClient.new
      end

      def call
        raise MissingSeller, "A Amazon não informou o selling_partner_id" if selling_partner_id.blank?

        oauth_state = OauthState.consume!(state)

        raise InvalidState, "State inválido, expirado ou já utilizado" if oauth_state.blank?

        raise InvalidState, "State de outra plataforma" unless oauth_state.platform == Settings::PLATFORM

        # O tenant sai do state — quem chama este endpoint é o navegador
        # redirecionado pela plataforma, sem sessão nossa.
        Current.with_tenant(oauth_state.tenant) do
          tokens = client.exchange_code(code: code, redirect_uri: Settings.redirect_uri)

          ActiveRecord::Base.transaction do
            conta = resolve_account!(oauth_state)

            persist_credential!(oauth_state, conta, tokens)
          end
        end
      end

      private

      attr_reader :code,
                  :selling_partner_id,
                  :state,
                  :client

      def resolve_account!(oauth_state)
        return oauth_state.platform_account if oauth_state.platform_account

        PlatformAccount.find_or_create_by!(
          tenant_id: oauth_state.tenant_id,
          platform: Settings::PLATFORM,
          external_id: selling_partner_id.to_s
        ) do |conta|
          conta.name = "Amazon #{selling_partner_id}"
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

          external_user_id: selling_partner_id.to_s,

          scope: tokens[:scope],

          status: :connected,

          last_refreshed_at: Time.current,

          refresh_failed_at: nil,

          refresh_error: nil,

          metadata: credencial.metadata.merge(
            "authorized_by_user_id" => oauth_state.user_id,
            "authorized_at" => Time.current,
            "selling_partner_id" => selling_partner_id.to_s
          )
        )

        credencial.save!

        credencial
      end
    end
  end
end
