require "net/http"
require "json"

module Marketplace
  module Clients
    # A integração financeira com o Mercado Livre AINDA NÃO ESTÁ IMPLEMENTADA.
    #
    # O `/financial/events` do esboço original não existe. A documentação aponta
    # para a família `/billing/integration` (parâmetro `group=ML` ou `group=MP`),
    # e o relatório de conciliação segue um fluxo assíncrono de três etapas:
    # gerar o relatório, consultar o status até ficar pronto, e só então baixar
    # (XLSX/CSV) — bem diferente de um GET paginado.
    #
    # Além disso a autenticação é OAuth 2.0 por vendedor: o access_token dura
    # 6 horas e o refresh_token é de uso único (validade de 6 meses), então é
    # preciso guardar e rotacionar os dois. Hoje só existe leitura de um
    # access_token estático no metadata, que expiraria em 6 horas.
    #
    # Doc: https://developers.mercadolivre.com.br/pt_br/billing-reports
    #      https://developers.mercadolivre.com.br/pt_br/conciliacoes
    #
    # A mecânica de transporte abaixo (auth, timeout, retry, paginação) fica
    # pronta para quando o fluxo real for construído.
    class MercadoLivreClient
      BASE_URL = "https://api.mercadolibre.com".freeze

      BILLING_INTEGRATION_PATH = "/billing/integration".freeze

      OPEN_TIMEOUT = 5

      READ_TIMEOUT = 30

      MAX_ATTEMPTS = 3

      PAGE_SIZE = 200

      MAX_PAGES = 500

      RETRIABLE = [
        Net::OpenTimeout,
        Net::ReadTimeout,
        Errno::ECONNRESET,
        Errno::ECONNREFUSED,
        SocketError
      ].freeze

      class Error < StandardError; end

      class AuthError < Error; end

      class NotImplemented < Error; end

      def initialize(access_token:)
        @access_token = access_token
      end

      def financial_events(start_date:, end_date:)
        raise NotImplemented,
              "Integração financeira do Mercado Livre não implementada. É preciso construir o fluxo " \
              "de relatórios de #{BILLING_INTEGRATION_PATH} (gerar -> consultar status -> baixar) e a " \
              "renovação do access_token OAuth, que expira em 6 horas. " \
              "Enquanto isso, use MARKETPLACE_SIMULATION=true em desenvolvimento."
      end

      private

      attr_reader :access_token

      def get(path, **query)
        uri = URI.join(BASE_URL, path)

        uri.query = URI.encode_www_form(query)

        parse!(request_with_retry(uri))
      end

      def request_with_retry(uri)
        attempt = 0

        begin
          attempt += 1

          perform(uri)
        rescue *RETRIABLE => e
          raise Error, "Falha de rede no Mercado Livre: #{e.class} #{e.message}" if attempt >= MAX_ATTEMPTS

          sleep(2**(attempt - 1))

          retry
        end
      end

      def perform(uri)
        http = Net::HTTP.new(uri.host, uri.port)

        http.use_ssl = true

        http.open_timeout = OPEN_TIMEOUT

        http.read_timeout = READ_TIMEOUT

        request = Net::HTTP::Get.new(uri)

        request["Authorization"] = "Bearer #{access_token}"

        request["Accept"] = "application/json"

        http.request(request)
      end

      def parse!(response)
        raise AuthError, "Token do Mercado Livre inválido ou expirado" if [401, 403].include?(response.code.to_i)

        raise Error, "Mercado Livre respondeu HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body.to_s)
      rescue JSON::ParserError
        raise Error, "Resposta não-JSON do Mercado Livre (HTTP #{response.code})"
      end
    end
  end
end
