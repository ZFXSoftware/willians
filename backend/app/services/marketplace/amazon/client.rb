require "net/http"
require "json"

module Marketplace
  module Amazon
    # Cliente da Selling Partner API.
    #
    # Autenticação é só o header `x-amz-access-token` — desde outubro de 2023 a
    # SP-API não exige mais assinatura AWS SigV4 nem IAM.
    #
    # A Finances API é limitada a 0,5 requisição por segundo (burst 30), ou seja
    # uma a cada 2 segundos em regime. O cliente respeita esse intervalo entre
    # chamadas, porque estourar rende 429 e a paginação de uma janela grande
    # dispara várias chamadas em sequência.
    class Client
      OPEN_TIMEOUT = 5

      READ_TIMEOUT = 30

      MAX_ATTEMPTS = 4

      # Intervalo mínimo entre chamadas (0,5 req/s = uma a cada 2s).
      MIN_INTERVAL = 2.0

      class Error < StandardError; end

      class AuthError < Error
        include Marketplace::CredencialRecusada
      end

      class RateLimited < Error
        include Marketplace::LimiteDeRequisicoes
      end

      class ApiError < Error
        attr_reader :code

        def initialize(message, code: nil)
          @code = code

          super(message)
        end
      end

      def initialize(access_token:)
        @access_token = access_token

        @ultima_chamada = nil
      end

      def get(path, params = {})
        respeitar_limite!

        attempt = 0

        begin
          attempt += 1

          parse!(perform(path, params), path)
        rescue RateLimited => e
          raise e if attempt >= MAX_ATTEMPTS

          # O 429 da Amazon pede recuo bem maior que o intervalo normal.
          sleep(MIN_INTERVAL * 5 * attempt)

          retry
        rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNRESET => e
          raise Error, "Falha de rede na Amazon: #{e.class} #{e.message}" if attempt >= MAX_ATTEMPTS

          sleep(2**(attempt - 1))

          retry
        end
      end

      private

      attr_reader :access_token

      def respeitar_limite!
        return if @ultima_chamada.blank?

        espera = MIN_INTERVAL - (Time.current - @ultima_chamada)

        sleep(espera) if espera.positive?
      end

      def perform(path, params)
        uri = URI.join(Settings.host, path)

        uri.query = URI.encode_www_form(params.compact) if params.compact.any?

        RedeExterna.bloquear!("a Amazon (SP-API)")


        http = Net::HTTP.new(uri.host, uri.port)

        http.use_ssl = true

        http.open_timeout = OPEN_TIMEOUT

        http.read_timeout = READ_TIMEOUT

        req = Net::HTTP::Get.new(uri)

        req["x-amz-access-token"] = access_token

        req["Accept"] = "application/json"

        @ultima_chamada = Time.current

        http.request(req)
      end

      def parse!(response, path)
        codigo = response.code.to_i

        raise AuthError, "Token da Amazon inválido ou sem permissão para #{path}" if [401, 403].include?(codigo)

        raise RateLimited, "Amazon limitou a taxa em #{path}" if codigo == 429

        parsed = JSON.parse(response.body.to_s)

        if parsed["errors"].present?
          erro = parsed["errors"].first || {}

          raise ApiError.new(
            "Amazon recusou #{path}: #{erro['code']} #{erro['message']}".strip,
            code: erro["code"]
          )
        end

        raise Error, "Amazon respondeu HTTP #{codigo} em #{path}" unless response.is_a?(Net::HTTPSuccess)

        parsed
      rescue JSON::ParserError
        raise Error, "Resposta não-JSON da Amazon em #{path} (HTTP #{response.code})"
      end
    end
  end
end
