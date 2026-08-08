require "net/http"
require "json"

module Marketplace
  module Amazon
    # Login with Amazon (LWA) para a Selling Partner API.
    #
    # Desde 2 de outubro de 2023 a SP-API NÃO exige mais AWS SigV4 nem IAM —
    # basta o access token LWA no header `x-amz-access-token`. A Amazon chega a
    # ignorar assinaturas SigV4 enviadas. Isso elimina toda a complexidade de
    # assinatura AWS que a integração exigia antes.
    #
    # O access token dura 1 hora. O refresh token não expira por tempo: vale até
    # o vendedor revogar o acesso do app.
    class OauthClient
      OPEN_TIMEOUT = 5

      READ_TIMEOUT = 20

      ACCESS_TOKEN_TTL = 1.hour

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

      def self.configured? = Settings.configured?

      # A autorização acontece no Seller Central, não num domínio de API.
      def authorization_url(state:, redirect_uri:)
        ensure_configured!

        uri = URI.parse(Settings.consent_url)

        uri.query = URI.encode_www_form(
          application_id: Settings.app_id,
          state: state,
          redirect_uri: redirect_uri
        )

        uri.to_s
      end

      # A Amazon devolve `spapi_oauth_code`, que é trocado por um refresh token
      # de longa duração.
      def exchange_code(code:, redirect_uri:)
        ensure_configured!

        post_token(
          grant_type: "authorization_code",
          code: code,
          redirect_uri: redirect_uri,
          client_id: Settings.client_id,
          client_secret: Settings.client_secret
        )
      end

      def refresh(refresh_token:)
        ensure_configured!

        post_token(
          grant_type: "refresh_token",
          refresh_token: refresh_token,
          client_id: Settings.client_id,
          client_secret: Settings.client_secret
        )
      end

      private

      def ensure_configured!
        return if Settings.configured?

        raise ConfigError,
              "AMAZON_CLIENT_ID/AMAZON_CLIENT_SECRET/AMAZON_APP_ID não configurados. " \
              "Registre o app no Seller Central e preencha o .env."
      end

      def post_token(body)
        uri = URI.parse(Settings.token_url)

        http = Net::HTTP.new(uri.host, uri.port)

        http.use_ssl = true

        http.open_timeout = OPEN_TIMEOUT

        http.read_timeout = READ_TIMEOUT

        req = Net::HTTP::Post.new(uri)

        req["Content-Type"] = "application/x-www-form-urlencoded"

        req["Accept"] = "application/json"

        req.body = URI.encode_www_form(body)

        normalize(parse!(http.request(req)))
      rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNRESET => e
        raise Error, "Falha de rede na Amazon: #{e.class} #{e.message}"
      end

      def parse!(response)
        parsed = JSON.parse(response.body.to_s)

        if parsed["error"].present?
          raise TokenError.new(
            "Amazon recusou a operação de token: #{parsed['error']} #{parsed['error_description']}".strip,
            code: parsed["error"]
          )
        end

        raise Error, "Amazon respondeu HTTP #{response.code} no token" unless response.is_a?(Net::HTTPSuccess)

        parsed
      rescue JSON::ParserError
        raise Error, "Resposta não-JSON da Amazon no token (HTTP #{response.code})"
      end

      # Mesmo formato dos outros marketplaces, para o TokenProvider tratar igual.
      def normalize(resposta)
        {
          access_token: resposta["access_token"],
          refresh_token: resposta["refresh_token"],
          expires_in: (resposta["expires_in"] || ACCESS_TOKEN_TTL.to_i).to_i,
          scope: resposta["scope"],
          user_id: nil,
          token_type: resposta["token_type"]
        }
      end
    end
  end
end
