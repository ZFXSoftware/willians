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

        # O tenant sai do state — quem chama este endpoint é o navegador
        # redirecionado pela plataforma, sem sessão nossa.
        Current.with_tenant(oauth_state.tenant) do
          tokens = exchange!(oauth_state)

          ActiveRecord::Base.transaction do
            account = resolve_platform_account!(oauth_state, tokens)

            persist_credential!(oauth_state, account, tokens)
          end
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
      #
      # Quem manda é o vendedor que AUTORIZOU, não a conta que o botão indicou.
      # Antes a conta indicada era devolvida sem mais nada, e reconectar um card
      # existente com outro login do Mercado Livre deixava o `external_id`
      # apontando para o vendedor antigo com o token do novo. As chamadas
      # seguintes perguntavam pelos pedidos de um vendedor usando o token de
      # outro, e o ML respondia 403 "caller.id does not match buyer or seller".
      def resolve_platform_account!(oauth_state, tokens)
        external_id = tokens[:user_id].to_s.presence

        return oauth_state.platform_account if external_id.blank?

        escopo = PlatformAccount.where(
          tenant_id: oauth_state.tenant_id, platform: Settings::PLATFORM
        )

        # Já existe a conta deste vendedor: é ela, mesmo que o botão tenha
        # partido de outro card.
        existente = escopo.find_by(external_id: external_id)

        return existente if existente

        indicada = oauth_state.platform_account

        return criar(oauth_state, external_id) if indicada.blank?

        renomear(indicada, external_id)

        indicada.update!(external_id: external_id)

        indicada
      end

      def criar(oauth_state, external_id)
        PlatformAccount.create!(
          tenant_id: oauth_state.tenant_id,
          platform: Settings::PLATFORM,
          external_id: external_id,
          name: "Mercado Livre #{external_id}",
          status: :active
        )
      end

      # Só mexe no nome se ele for o automático: nome escrito por alguém é
      # informação, e trocar por "Mercado Livre 123" apagaria isso.
      def renomear(conta, external_id)
        return unless conta.name.to_s.strip == "Mercado Livre #{conta.external_id}"

        conta.name = "Mercado Livre #{external_id}"
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

          # Autorização sem acesso offline não devolve token de renovação: o
          # acesso dura 6 horas e acaba. Gravar isso AGORA é o que faz a tela
          # avisar hoje, em vez de a conta simplesmente parar de sincronizar
          # amanhã com uma mensagem crua da plataforma.
          refresh_error: aviso_de_acesso_offline(tokens),

          metadata: credential.metadata.merge(
            "authorized_by_user_id" => oauth_state.user_id,
            "authorized_at" => Time.current
          )
        )

        credential.save!

        credential
      end

      def aviso_de_acesso_offline(tokens)
        return if tokens[:refresh_token].present?

        Rails.logger.warn(
          "[MercadoLivre] conta #{tokens[:user_id]} autorizada SEM refresh_token: " \
          "o aplicativo está sem acesso offline no painel do Mercado Livre."
        )

        "Conectada sem acesso offline: o Mercado Livre não devolveu token de renovação, " \
        "e este acesso expira em poucas horas. Ligue o acesso offline do aplicativo no " \
        "painel do Mercado Livre e conecte a conta de novo."
      end

      def expires_at_for(tokens)
        seconds = tokens[:expires_in].to_i

        seconds.positive? ? seconds.seconds.from_now : 6.hours.from_now
      end
    end
  end
end
