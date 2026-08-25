require "net/http"
require "json"

module Marketplace
  module MercadoLivre
    # API de Relatórios de Faturamento do Mercado Livre.
    #
    # Endpoints e campos conferidos na documentação (versão de 03/03/2026):
    #
    #   GET /billing/integration/monthly/periods
    #   GET /billing/integration/periods/key/$KEY/documents
    #   GET /billing/integration/periods/key/$KEY/summary/details
    #
    # `group` é ML (o que o Mercado Livre cobra do vendedor) ou MP (Mercado
    # Pago). Omitir devolve os dois.
    #
    # A doc pede consumo sequencial e diário — não use em lote apertado. O 429 é
    # bloqueio preventivo por IP, e o 206 significa resposta incompleta, que deve
    # ser repetida.
    class BillingClient
      BASE_PATH = "/billing/integration".freeze

      GROUPS = %w[ML MP].freeze

      DOCUMENT_TYPES = %w[BILL CREDIT_NOTE].freeze

      # O site MLM (México) usa expiration_date onde os demais usam key.
      KEY_BY_EXPIRATION_SITES = %w[MLM].freeze

      MAX_PERIODS = 12

      OPEN_TIMEOUT = 5

      READ_TIMEOUT = 30

      MAX_ATTEMPTS = 4

      class Error < StandardError; end

      class AuthError < Error
        include Marketplace::CredencialRecusada
      end

      class RateLimited < Error
        include Marketplace::LimiteDeRequisicoes
      end

      class PartialContent < Error; end

      def initialize(access_token:)
        @access_token = access_token
      end

      # => Array de períodos (mais recentes primeiro, conforme a API devolve)
      def periods(group: nil, document_type: "BILL", offset: 0, limit: MAX_PERIODS)
        validate_group!(group)

        validate_document_type!(document_type)

        response = get(
          "#{BASE_PATH}/monthly/periods",
          group: group,
          document_type: document_type,
          offset: offset,
          limit: [limit, MAX_PERIODS].min
        )

        response["results"] || []
      end

      def documents(key:, group: nil, document_type: nil, offset: 0, limit: 150)
        validate_group!(group)

        validate_document_type!(document_type) if document_type

        response = get(
          "#{BASE_PATH}/periods/key/#{key}/documents",
          group: group,
          document_type: document_type,
          offset: offset,
          limit: limit
        )

        response["results"] || []
      end

      # Resumo de encargos e bonificações do período.
      def summary(key:, group: nil)
        validate_group!(group)

        get("#{BASE_PATH}/periods/key/#{key}/summary/details", group: group)
      end

      # A chave para consumir documents/details/summary depende do site.
      def self.period_key_for(period, site_id: nil)
        return period["expiration_date"] if KEY_BY_EXPIRATION_SITES.include?(site_id.to_s)

        period["key"]
      end

      private

      attr_reader :access_token

      def validate_group!(group)
        return if group.blank? || GROUPS.include?(group.to_s)

        raise ArgumentError, "group inválido: #{group}. Use #{GROUPS.join(' ou ')}."
      end

      def validate_document_type!(document_type)
        return if DOCUMENT_TYPES.include?(document_type.to_s)

        raise ArgumentError, "document_type inválido: #{document_type}. Use #{DOCUMENT_TYPES.join(' ou ')}."
      end

      def get(path, **query)
        uri = URI.join(api_host, path)

        params = query.compact

        uri.query = URI.encode_www_form(params) if params.any?

        parse!(request_with_retry(uri))
      end

      def api_host
        ENV["ML_API_HOST"].presence || "https://api.mercadolibre.com"
      end

      # 206 e 429 são retentáveis; o resto sobe na hora.
      def request_with_retry(uri)
        attempt = 0

        begin
          attempt += 1

          response = perform(uri)

          raise PartialContent, "Resposta incompleta (206)" if response.code.to_i == 206

          raise RateLimited, "Bloqueio por excesso de requisições (429)" if response.code.to_i == 429

          response
        rescue PartialContent, RateLimited => e
          raise e if attempt >= MAX_ATTEMPTS

          sleep(backoff_for(attempt, e))

          retry
        rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNRESET => e
          raise Error, "Falha de rede no faturamento do Mercado Livre: #{e.class} #{e.message}" if attempt >= MAX_ATTEMPTS

          sleep(backoff_for(attempt, e))

          retry
        end
      end

      # O 429 é bloqueio por IP: espera bem mais que uma falha comum.
      def backoff_for(attempt, error)
        base = error.is_a?(RateLimited) ? 15 : 2

        base * (2**(attempt - 1))
      end

      def perform(uri)
        RedeExterna.bloquear!("o faturamento do Mercado Livre")

        http = Net::HTTP.new(uri.host, uri.port)

        http.use_ssl = uri.scheme == "https"

        http.open_timeout = OPEN_TIMEOUT

        http.read_timeout = READ_TIMEOUT

        request = Net::HTTP::Get.new(uri)

        request["Authorization"] = "Bearer #{access_token}"

        request["Accept"] = "application/json"

        http.request(request)
      end

      def parse!(response)
        raise AuthError, "Token do Mercado Livre inválido ou expirado" if [401, 403].include?(response.code.to_i)

        raise Error, "Faturamento do Mercado Livre respondeu HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body.to_s)
      rescue JSON::ParserError
        raise Error, "Resposta não-JSON do faturamento (HTTP #{response.code})"
      end
    end
  end
end
