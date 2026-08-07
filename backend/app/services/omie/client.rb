require "net/http"
require "json"

module Omie
  class Client
    BASE_URL = "https://app.omie.com.br/api/v1"

    OPEN_TIMEOUT = 5

    READ_TIMEOUT = 30

    MAX_ATTEMPTS = 3

    RETRIABLE = [
      Net::OpenTimeout,
      Net::ReadTimeout,
      Errno::ECONNRESET,
      Errno::ECONNREFUSED,
      Errno::EHOSTUNREACH,
      SocketError
    ].freeze

    # Qualquer chamada que não seja de leitura grava no ERP do cliente. O padrão
    # é bloquear: durante os testes com credencial real, uma escrita acidental
    # cria títulos e baixas de verdade na contabilidade dele.
    READ_PREFIXES = %w[Listar Consultar Pesquisar Obter].freeze

    class Error < StandardError; end

    class TransportError < Error; end

    class WriteBlocked < Error; end

    class ApiError < Error
      attr_reader :fault_code

      def initialize(message, fault_code: nil)
        @fault_code = fault_code

        super(message)
      end
    end

    def self.configured?
      ENV["OMIE_APP_KEY"].present? &&
        ENV["OMIE_APP_SECRET"].present?
    end

    # Allowlist estrita de propósito. O cast booleano do Rails trata "no", "nao"
    # e "desligado" como VERDADEIRO — um valor desses no .env liberaria escrita
    # no ERP do cliente justamente quem tentou desligá-la.
    WRITE_ENABLED_VALUES = %w[true 1].freeze

    def self.writes_enabled?
      WRITE_ENABLED_VALUES.include?(ENV["OMIE_ALLOW_WRITES"].to_s.strip.downcase)
    end

    def self.read_only_call?(call)
      READ_PREFIXES.any? { |prefix| call.to_s.start_with?(prefix) }
    end

    def initialize(
      app_key: ENV["OMIE_APP_KEY"],
      app_secret: ENV["OMIE_APP_SECRET"]
    )
      @app_key = app_key
      @app_secret = app_secret
    end

    def request(endpoint, call, params = {})
      guard_write!(call)

      body = {
        call: call,
        app_key: app_key,
        app_secret: app_secret,
        param: [params]
      }

      response = post_with_retry(
        uri_for(endpoint),
        body
      )

      parse!(response, call)
    end

    private

    attr_reader :app_key,
                :app_secret

    def guard_write!(call)
      return if self.class.read_only_call?(call)

      return if self.class.writes_enabled?

      raise WriteBlocked,
            "Chamada de escrita '#{call}' bloqueada. Defina OMIE_ALLOW_WRITES=true " \
            "para permitir gravação no OMIE do cliente."
    end

    def uri_for(endpoint)
      URI.join(
        "#{BASE_URL}/",
        endpoint.to_s.delete_prefix("/")
      )
    end

    def post_with_retry(uri, body)
      attempt = 0

      begin
        attempt += 1

        post(uri, body)
      rescue *RETRIABLE => e
        raise TransportError, "Falha de rede ao chamar Omie: #{e.class} #{e.message}" if attempt >= MAX_ATTEMPTS

        sleep(backoff_for(attempt))

        retry
      end
    end

    def post(uri, body)
      http = Net::HTTP.new(uri.host, uri.port)

      http.use_ssl = uri.scheme == "https"

      http.open_timeout = OPEN_TIMEOUT

      http.read_timeout = READ_TIMEOUT

      request = Net::HTTP::Post.new(uri)

      request["Content-Type"] = "application/json"

      request.body = body.to_json

      http.request(request)
    end

    def backoff_for(attempt)
      2**(attempt - 1)
    end

    # O Omie responde 500 com corpo JSON para erros de negócio, então o
    # faultstring precisa ser inspecionado antes do código HTTP.
    def parse!(response, call)
      parsed = JSON.parse(response.body.to_s)

      if parsed.is_a?(Hash) && parsed["faultstring"].present?
        raise ApiError.new(
          "Erro Omie em #{call}: #{parsed['faultstring']}",
          fault_code: parsed["faultcode"]
        )
      end

      unless response.is_a?(Net::HTTPSuccess)
        raise ApiError.new(
          "Erro Omie em #{call}: HTTP #{response.code}"
        )
      end

      parsed
    rescue JSON::ParserError
      raise ApiError.new(
        "Resposta não-JSON do Omie em #{call}: HTTP #{response.code}"
      )
    end
  end
end
