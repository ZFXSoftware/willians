module Marketplace
  module MercadoLivre
    # Passo 2 do OAuth: valida o `state`, troca o `code` por tokens e guarda a
    # credencial.
    #
    # O endpoint que chama isto é público — quem bate nele é o navegador
    # redirecionado pelo ML, sem sessão. Toda a confiança vem do `state`, que é
    # de uso único e carrega tenant e usuário.
    class Callback
      class InvalidState < StandardError; end

      def initialize(code:, state:, client: nil)
        @code = code

        @state = state

        @client = client || OauthClient.new
      end

      def call
        oauth_state = OauthState.consume!(state)

        raise InvalidState, "State inválido, expirado ou já utilizado" if oauth_state.blank?

        raise InvalidState, "State de outra plataforma" unless oauth_state.platform == Settings::PLATFORM

        tokens = exchange!(oauth_state)

        ActiveRecord::Base.transaction do
          account = resolve_platform_account!(oauth_state, tokens)

          persist_credential!(oauth_state, account, tokens)
        end
      end

      private

      attr_reader :code,
                  :state,
                  :client

      def exchange!(oauth_state)
        client.exchange_code(
          code: code,
          redirect_uri: Settings.redirect_uri,
          code_verifier: oauth_state.code_verifier
        )
      end

      # O external_id da conta é o user_id do vendedor no ML, que só é conhecido
      # depois da troca — por isso a conta pode ser criada aqui.
      def resolve_platform_account!(oauth_state, tokens)
        return oauth_state.platform_account if oauth_state.platform_account

        external_id = tokens[:user_id].to_s

        PlatformAccount.find_or_create_by!(
          tenant_id: oauth_state.tenant_id,
          platform: Settings::PLATFORM,
          external_id: external_id
        ) do |account|
          account.name = "Mercado Livre #{external_id}"
          account.status = :active
        end
      end

      def persist_credential!(oauth_state, account, tokens)
        credential =
          MarketplaceCredential.find_or_initialize_by(platform_account_id: account.id)

        credential.assign_attributes(
          tenant_id: oauth_state.tenant_id,

          platform: Settings::PLATFORM,

          access_token: tokens[:access_token],

          refresh_token: tokens[:refresh_token],

          expires_at: expires_at_for(tokens),

          external_user_id: tokens[:user_id].to_s.presence,

          scope: tokens[:scope],

          status: :connected,

          last_refreshed_at: Time.current,

          refresh_failed_at: nil,

          refresh_error: nil,

          metadata: credential.metadata.merge(
            "authorized_by_user_id" => oauth_state.user_id,
            "authorized_at" => Time.current
          )
        )

        credential.save!

        credential
      end

      def expires_at_for(tokens)
        seconds = tokens[:expires_in].to_i

        seconds.positive? ? seconds.seconds.from_now : 6.hours.from_now
      end
    end
  end
end
