require "net/http"
require "json"

module Marketplace
  module MercadoLivre
    # Fluxo Authorization Code do Mercado Livre.
    #
    # Os hosts são configuráveis por ambiente porque as páginas de documentação
    # do ML bloqueiam acesso automatizado e não deu para conferir os valores
    # linha a linha — se algum estiver errado, é ajuste de .env, não de código.
    #
    # ATENÇÃO: nenhuma operação de token faz retry. O `code` é de uso único e o
    # `refresh_token` também — repetir uma chamada que na verdade funcionou (mas
    # cuja resposta se perdeu) queima a credencial e desconecta o lojista.
    class OauthClient
      DEFAULT_AUTH_HOST = "https://auth.mercadolivre.com.br".freeze

      DEFAULT_API_HOST = "https://api.mercadolibre.com".freeze

      TOKEN_PATH = "/oauth/token".freeze

      OPEN_TIMEOUT = 5

      READ_TIMEOUT = 20

      class Error < StandardError; end

      class ConfigError < Error; end

      class TokenError < Error
        include Marketplace::TokenRefreshRejected

        attr_reader :code

        def initialize(message, code: nil)
          @code = code

          super(message)
        end
      end

      PROVEDOR = "mercado_livre".freeze

      def self.configured?(tenant: Current.tenant)
        Integracoes::Config.configurado?(PROVEDOR, tenant: tenant)
      end

      # As credenciais vêm da tela de configurações do tenant, com o ambiente
      # como fallback. Ainda dá para injetar direto — os testes usam isso.
      def initialize(client_id: nil, client_secret: nil, tenant: nil)
        @client_id_informado = client_id

        @client_secret_informado = client_secret

        @tenant = tenant
      end

      # Resolvidas a cada uso: o cliente é montado antes de o contexto do
      # tenant existir em boa parte dos caminhos.
      def client_id
        @client_id_informado || Integracoes::Config.get(PROVEDOR, :client_id, tenant: tenant_efetivo)
      end

      def client_secret
        @client_secret_informado || Integracoes::Config.get(PROVEDOR, :client_secret, tenant: tenant_efetivo)
      end

      def tenant_efetivo
        @tenant || Current.tenant
      end

      def authorization_url(state:, redirect_uri:, code_challenge: nil)
        ensure_configured!

        params = {
          response_type: "code",
          client_id: client_id,
          redirect_uri: redirect_uri,
          state: state
        }

        if code_challenge.present?
          params[:code_challenge] = code_challenge
          params[:code_challenge_method] = "S256"
        end

        uri = URI.join(auth_host, "/authorization")

        uri.query = URI.encode_www_form(params)

        uri.to_s
      end

      def exchange_code(code:, redirect_uri:, code_verifier: nil)
        ensure_configured!

        body = {
          grant_type: "authorization_code",
          client_id: client_id,
          client_secret: client_secret,
          code: code,
          redirect_uri: redirect_uri
        }

        body[:code_verifier] = code_verifier if code_verifier.present?

        post_token(body)
      end

      def refresh(refresh_token:)
        ensure_configured!

        post_token(
          grant_type: "refresh_token",
          client_id: client_id,
          client_secret: client_secret,
          refresh_token: refresh_token
        )
      end

      private


      def ensure_configured!
        return if client_id.present? && client_secret.present?

        raise ConfigError,
              "Credenciais do Mercado Livre não configuradas. Registre o app no portal " \
              "de desenvolvedores e preencha Client ID e Client Secret em Integrações → " \
              "Configurações."
      end

      def auth_host
        ENV["ML_AUTH_HOST"].presence || DEFAULT_AUTH_HOST
      end

      def api_host
        ENV["ML_API_HOST"].presence || DEFAULT_API_HOST
      end

      def post_token(body)
        uri = URI.join(api_host, TOKEN_PATH)

        response = perform(uri, body)

        parse_token!(response)
      end

      def perform(uri, body)
        RedeExterna.bloquear!("o OAuth do Mercado Livre")

        http = Net::HTTP.new(uri.host, uri.port)

        http.use_ssl = uri.scheme == "https"

        http.open_timeout = OPEN_TIMEOUT

        http.read_timeout = READ_TIMEOUT

        request = Net::HTTP::Post.new(uri)

        request["Content-Type"] = "application/x-www-form-urlencoded"

        request["Accept"] = "application/json"

        request.body = URI.encode_www_form(body)

        http.request(request)
      rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNRESET => e
        raise Error, "Falha de rede ao falar com o Mercado Livre: #{e.class} #{e.message}"
      end

      def parse_token!(response)
        parsed = JSON.parse(response.body.to_s)

        unless response.is_a?(Net::HTTPSuccess)
          raise TokenError.new(
            "Mercado Livre recusou a operação de token: " \
            "#{parsed['error']} #{parsed['message'] || parsed['error_description']}".strip,
            code: parsed["error"]
          )
        end

        {
          access_token: parsed["access_token"],
          refresh_token: parsed["refresh_token"],
          expires_in: parsed["expires_in"],
          scope: parsed["scope"],
          user_id: parsed["user_id"],
          token_type: parsed["token_type"]
        }
      rescue JSON::ParserError
        raise Error, "Resposta não-JSON do Mercado Livre (HTTP #{response.code})"
      end
    end
  end
end
