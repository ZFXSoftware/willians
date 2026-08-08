require "net/http"
require "json"

module Marketplace
  module Shopee
    # Transporte assinado da API v2 da Shopee.
    #
    # Diferente do Mercado Livre, aqui não há Bearer: a autenticação vai na
    # query string de toda chamada, com assinatura HMAC calculada sobre o
    # caminho e o timestamp. Ver Marketplace::Shopee::Signature.
    #
    # A Shopee responde HTTP 200 mesmo em erro de negócio, sinalizando pelo
    # campo `error` do corpo — por isso o código HTTP sozinho não serve.
    class Client
      OPEN_TIMEOUT = 5

      READ_TIMEOUT = 30

      MAX_ATTEMPTS = 3

      RETRIABLE_NET = [
        Net::OpenTimeout,
        Net::ReadTimeout,
        Errno::ECONNRESET,
        Errno::ECONNREFUSED,
        SocketError
      ].freeze

      # Erros que valem nova tentativa; os demais são definitivos.
      RETRIABLE_ERRORS = %w[
        error_server
        error_busy
        error_inner
      ].freeze

      TOKEN_ERRORS = %w[
        error_auth
        error_token
        invalid_access_token
        error_permission
      ].freeze

      class Error < StandardError; end

      class AuthError < Error
        include Marketplace::TokenRefreshRejected
      end

      class ApiError < Error
        include Marketplace::TokenRefreshRejected

        attr_reader :code

        def initialize(message, code: nil)
          @code = code

          super(message)
        end
      end

      def initialize(access_token: nil, shop_id: nil)
        @access_token = access_token

        @shop_id = shop_id
      end

      def get(path_key, params = {})
        request(:get, path_key, params)
      end

      def post(path_key, body = {})
        request(:post, path_key, body)
      end

      # Chamadas públicas (obter/renovar token) não levam access_token nem
      # shop_id na assinatura.
      def post_public(path_key, body = {})
        request(:post, path_key, body, signed_as_shop: false)
      end

      private

      attr_reader :access_token,
                  :shop_id

      def request(verb, path_key, payload, signed_as_shop: true)
        path = Settings.path(path_key)

        ensure_partner_credentials!

        attempt = 0

        begin
          attempt += 1

          parse!(perform(verb, path, payload, signed_as_shop), path_key)
        rescue *RETRIABLE_NET => e
          raise Error, "Falha de rede na Shopee: #{e.class} #{e.message}" if attempt >= MAX_ATTEMPTS

          sleep(2**(attempt - 1))

          retry
        rescue ApiError => e
          raise e unless RETRIABLE_ERRORS.include?(e.code.to_s)

          raise e if attempt >= MAX_ATTEMPTS

          sleep(2**(attempt - 1))

          retry
        end
      end

      def ensure_partner_credentials!
        return if Settings.configured?

        raise Error,
              "SHOPEE_PARTNER_ID/SHOPEE_PARTNER_KEY não configurados. Registre o app " \
              "no Shopee Open Platform e preencha o .env."
      end

      def signature
        @signature ||= Signature.new(
          partner_id: Settings.partner_id,
          partner_key: Settings.partner_key
        )
      end

      def perform(verb, path, payload, signed_as_shop)
        uri = URI.join(Settings.host, path)

        query = signature.query_for(
          path: path,
          access_token: signed_as_shop ? access_token : nil,
          shop_id: signed_as_shop ? shop_id : nil
        )

        # No GET os filtros vão junto da query assinada; a assinatura cobre só
        # caminho e timestamp, então acrescentar parâmetros não a invalida.
        query = query.merge(payload) if verb == :get

        uri.query = URI.encode_www_form(query)

        http = Net::HTTP.new(uri.host, uri.port)

        http.use_ssl = uri.scheme == "https"

        http.open_timeout = OPEN_TIMEOUT

        http.read_timeout = READ_TIMEOUT

        req =
          if verb == :get
            Net::HTTP::Get.new(uri)
          else
            Net::HTTP::Post.new(uri).tap do |r|
              r["Content-Type"] = "application/json"
              r.body = payload.to_json
            end
          end

        req["Accept"] = "application/json"

        http.request(req)
      end

      def parse!(response, path_key)
        parsed = JSON.parse(response.body.to_s)

        erro = parsed["error"].to_s

        if erro.present?
          mensagem = "Shopee recusou #{path_key}: #{erro} #{parsed['message']}".strip

          raise AuthError, mensagem if TOKEN_ERRORS.include?(erro)

          raise ApiError.new(mensagem, code: erro)
        end

        unless response.is_a?(Net::HTTPSuccess)
          raise Error, "Shopee respondeu HTTP #{response.code} em #{path_key}"
        end

        parsed
      rescue JSON::ParserError
        raise Error, "Resposta não-JSON da Shopee em #{path_key} (HTTP #{response.code})"
      end
    end
  end
end
