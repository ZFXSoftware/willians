require "digest"

module Marketplace
  module MercadoLivre
    # Passo 1 do OAuth: gera o `state` e monta a URL para onde o lojista vai
    # autorizar o app.
    class Authorization
      def initialize(tenant:, user:, platform_account: nil, client: nil)
        @tenant = tenant

        @user = user

        @platform_account = platform_account

        @client = client || OauthClient.new
      end

      def call
        verifier = pkce_verifier

        state = OauthState.issue!(
          platform: Settings::PLATFORM,
          tenant: tenant,
          user: user,
          platform_account: platform_account,
          code_verifier: verifier
        )

        {
          authorization_url: client.authorization_url(
            state: state.state,
            redirect_uri: Settings.redirect_uri,
            code_challenge: challenge_for(verifier)
          ),
          state: state.state,
          expires_at: state.expires_at
        }
      end

      private

      attr_reader :tenant,
                  :user,
                  :platform_account,
                  :client

      # PKCE é opcional no ML e só vira obrigatório se estiver habilitado no
      # cadastro do app. Fica atrás de flag para que ligar seja trocar o .env.
      def pkce_verifier
        return unless pkce_enabled?

        SecureRandom.urlsafe_base64(64)
      end

      def challenge_for(verifier)
        return if verifier.blank?

        Base64.urlsafe_encode64(
          Digest::SHA256.digest(verifier),
          padding: false
        )
      end

      def pkce_enabled?
        %w[true 1].include?(ENV["ML_USE_PKCE"].to_s.strip.downcase)
      end
    end
  end
end
