module Marketplace
  module Credentials
    # Entrega um access_token válido, renovando quando está perto de vencer.
    #
    # O refresh_token costuma ser de USO ÚNICO: cada renovação devolve um novo e
    # invalida o anterior. Duas renovações concorrentes desconectariam a conta,
    # então a renovação acontece sob lock de linha — quem chega depois recarrega
    # e vê que já foi renovado.
    #
    # Recusa definitiva é sinalizada por Marketplace::TokenRefreshRejected, que
    # todas as plataformas marcam nos seus erros de token.
    class TokenProvider
      # A Shopee assina cada chamada com o shop_id, então o cliente precisa
      # nascer sabendo de qual loja é — por isso a conta entra na construção,
      # mantendo `refresh(refresh_token:)` igual para todas as plataformas.
      OAUTH_CLIENTS = {
        "mercado_livre" => ->(_account) { Marketplace::MercadoLivre::OauthClient.new },
        "shopee" => ->(account) { Marketplace::Shopee::OauthClient.new(shop_id: account.external_id) },
        "amazon" => ->(_account) { Marketplace::Amazon::OauthClient.new }
      }.freeze

      class MissingCredential < StandardError; end

      class NeedsReauthorization < StandardError; end

      class UnsupportedPlatform < StandardError; end

      def initialize(platform_account:, client: nil)
        @platform_account = platform_account

        @client = client
      end

      def access_token
        Current.with_tenant(platform_account.tenant) do
          credential = fetch_credential!

          credential = refresh!(credential) if credential.needs_refresh?

          credential.access_token
        end
      end

      # A falha é registrada FORA do lock de propósito: `with_lock` abre uma
      # transação, e levantar de dentro dela desfaria o próprio registro da
      # falha no rollback.
      # As credenciais de app são do tenant dono da conta, não de quem chamou:
      # o job de renovação roda sem requisição e passa por aqui.
      def refresh!(credential = fetch_credential!)
        failure = nil

        temporary = nil

        # Escopo restaurável, não atribuição: o job de renovação percorre
        # credenciais de tenants diferentes numa execução só.
        Current.with_tenant(platform_account.tenant) do
          credential.with_lock do
            # Outra thread pode ter renovado enquanto esperávamos o lock.
            next unless credential.needs_refresh?

            begin
              perform_refresh!(credential)
            rescue Marketplace::TokenRefreshRejected => e
              failure = e
            rescue StandardError => e
              # Falha passageira. Guardada para aparecer na tela, e relançada
              # depois do lock — mas SEM desconectar: só a plataforma dizendo
              # que o refresh_token morreu justifica pedir um OAuth novo.
              temporary = e
            end
          end
        end

        handle_failure!(credential, failure) if failure

        handle_retry!(credential, temporary) if temporary

        credential
      end

      private

      attr_reader :platform_account

      def fetch_credential!
        credential = MarketplaceCredential.find_by(platform_account_id: platform_account.id)

        if credential.blank?
          raise MissingCredential,
                "Conta ##{platform_account.id} (#{platform_account.platform}) não foi conectada. " \
                "Autorize o acesso pela tela de Integrações."
        end

        unless credential.connected?
          raise NeedsReauthorization,
                "Credencial da conta ##{platform_account.id} está #{credential.status}. " \
                "É preciso autorizar novamente."
        end

        credential
      end

      def perform_refresh!(credential)
        exigir_refresh_token!(credential)

        tokens = oauth_client.refresh(refresh_token: credential.refresh_token)

        credential.update!(
          access_token: tokens[:access_token],

          # Sempre grave o novo refresh_token: o antigo acabou de ser invalidado.
          refresh_token: tokens[:refresh_token].presence || credential.refresh_token,

          expires_at: expires_at_for(tokens),

          scope: tokens[:scope].presence || credential.scope,

          last_refreshed_at: Time.current,

          refresh_failed_at: nil,

          refresh_error: nil
        )
      end

      # Sem refresh_token não há renovação possível, e mandar a requisição
      # assim faz a plataforma devolver a própria reclamação dela na cara do
      # usuário: "Missing parameters: refresh_token". Isso não diz o que fazer,
      # e parece defeito de código.
      #
      # A causa costuma ser uma só: a autorização foi concedida sem acesso
      # OFFLINE. O Mercado Livre só devolve refresh_token quando o aplicativo
      # tem essa opção ligada no painel dele — sem ela o acesso dura 6 horas e
      # acaba, e não há o que renovar.
      #
      # É recusa definitiva de propósito: nenhuma tentativa futura vai
      # funcionar, e insistir de hora em hora só empurraria o problema.
      def exigir_refresh_token!(credential)
        return if credential.refresh_token.present?

        raise Marketplace::SemRefreshToken,
              "A conta #{platform_account.platform} foi conectada sem acesso offline, " \
              "então não veio um token de renovação e o acesso expira em poucas horas. " \
              "No painel do #{platform_account.platform}, ligue o acesso offline do " \
              "aplicativo e conecte a conta de novo em Integrações."
      end

      # Refresh recusado é definitivo: o lojista precisa autorizar de novo.
      def handle_failure!(credential, error)
        credential.mark_refresh_failure!(error.message)

        raise NeedsReauthorization,
              "Renovação recusada pelo #{platform_account.platform}: #{error.message}"
      end

      # A conta continua conectada: a próxima renovação tenta de novo. O erro
      # sobe para quem chamou decidir o que fazer com a requisição em curso.
      def handle_retry!(credential, error)
        Rails.logger.warn(
          "[TokenProvider] conta ##{platform_account.id} " \
          "(#{platform_account.platform}) não renovou agora, segue conectada: " \
          "#{error.class} #{error.message}"
        )

        credential.mark_refresh_retry!(error.message)

        raise error
      end

      def expires_at_for(tokens)
        seconds = tokens[:expires_in].to_i

        seconds.positive? ? seconds.seconds.from_now : 6.hours.from_now
      end

      def oauth_client
        @client ||= begin
          fabrica = OAUTH_CLIENTS[platform_account.platform.to_s]

          raise UnsupportedPlatform, "Sem cliente OAuth para #{platform_account.platform}" if fabrica.blank?

          fabrica.call(platform_account)
        end
      end
    end
  end
end
