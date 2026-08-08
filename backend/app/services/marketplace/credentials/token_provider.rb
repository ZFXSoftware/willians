module Marketplace
  module Credentials
    # Entrega um access_token válido, renovando quando está perto de vencer.
    #
    # O refresh_token do Mercado Livre é de USO ÚNICO: cada renovação devolve um
    # novo e invalida o anterior. Duas renovações concorrentes desconectariam a
    # conta, então a renovação acontece sob lock de linha — quem chega depois
    # recarrega e vê que já foi renovado.
    class TokenProvider
      # A Shopee assina cada chamada com o shop_id, então o cliente precisa
      # nascer sabendo de qual loja é — por isso a conta entra na construção,
      # mantendo `refresh(refresh_token:)` igual para todas as plataformas.
      OAUTH_CLIENTS = {
        "mercado_livre" => ->(_account) { Marketplace::MercadoLivre::OauthClient.new },
        "shopee" => ->(account) { Marketplace::Shopee::OauthClient.new(shop_id: account.external_id) }
      }.freeze

      class MissingCredential < StandardError; end

      class NeedsReauthorization < StandardError; end

      class UnsupportedPlatform < StandardError; end

      def initialize(platform_account:, client: nil)
        @platform_account = platform_account

        @client = client
      end

      def access_token
        credential = fetch_credential!

        credential = refresh!(credential) if credential.needs_refresh?

        credential.access_token
      end

      # A falha é registrada FORA do lock de propósito: `with_lock` abre uma
      # transação, e levantar de dentro dela desfaria o próprio registro da
      # falha no rollback.
      def refresh!(credential = fetch_credential!)
        failure = nil

        credential.with_lock do
          # Outra thread pode ter renovado enquanto esperávamos o lock.
          next unless credential.needs_refresh?

          begin
            perform_refresh!(credential)
          rescue Marketplace::MercadoLivre::OauthClient::TokenError => e
            failure = e
          end
        end

        handle_failure!(credential, failure) if failure

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

      # Refresh recusado é definitivo: o lojista precisa autorizar de novo.
      def handle_failure!(credential, error)
        credential.mark_refresh_failure!(error.message)

        raise NeedsReauthorization,
              "Renovação recusada pelo #{platform_account.platform}: #{error.message}"
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
