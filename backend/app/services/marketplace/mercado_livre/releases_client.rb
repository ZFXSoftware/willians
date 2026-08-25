require "net/http"
require "json"

module Marketplace
  module MercadoLivre
    # Relatório de Liberações do Mercado Pago — o extrato do dinheiro.
    #
    # Endpoints conferidos na documentação (agosto/2026):
    #
    #   POST /v1/account/release_report            cria o relatório do período
    #   GET  /v1/account/release_report/list       lista os já gerados
    #   GET  /v1/account/release_report/$ARQUIVO   baixa o CSV
    #
    # A geração é ASSÍNCRONA: o POST responde 202 e o arquivo aparece na lista
    # alguns minutos depois. Por isso o fluxo é criar, esperar e baixar — e
    # reaproveitar um relatório já existente do mesmo período quando houver,
    # que é o caso comum de reprocessamento.
    class ReleasesClient
      BASE_PATH = "/v1/account/release_report".freeze

      OPEN_TIMEOUT = 5

      READ_TIMEOUT = 60

      # A doc não promete prazo; alguns minutos é o observado. Além disso, o
      # trabalho é retomável: o relatório continua sendo gerado e a próxima
      # execução o encontra pronto na lista.
      DEFAULT_TIMEOUT = 180

      POLL_INTERVAL = 5

      class Error < StandardError; end

      class AuthError < Error; end

      class RateLimited < Error; end

      # O relatório não ficou pronto dentro da janela de espera. Não é falha:
      # a próxima execução encontra o arquivo pronto.
      class ReportPending < Error
        include Marketplace::Providers::AindaNaoPronto
      end

      def initialize(access_token:, timeout: DEFAULT_TIMEOUT, sleeper: nil)
        @access_token = access_token

        @timeout = timeout

        # Injetável para que o teste não espere de verdade.
        @sleeper = sleeper || ->(segundos) { sleep(segundos) }
      end

      # Devolve o CSV do período, gerando o relatório se ainda não existir.
      def csv_for(start_date:, end_date:)
        existente = encontrar(start_date, end_date)

        return download(existente) if existente

        criar(start_date: start_date, end_date: end_date)

        download(aguardar(start_date, end_date))
      end

      def criar(start_date:, end_date:)
        post(BASE_PATH, begin_date: iso(start_date), end_date: iso(end_date, fim_do_dia: true))
      end

      def relatorios
        resposta = get("#{BASE_PATH}/list")

        resposta.is_a?(Array) ? resposta : (resposta["results"] || [])
      end

      def download(arquivo)
        nome = arquivo.is_a?(Hash) ? arquivo["file_name"] : arquivo.to_s

        raise Error, "Relatório sem nome de arquivo" if nome.blank?

        corpo(get_raw("#{BASE_PATH}/#{nome}"))
      end

      private

      attr_reader :access_token,
                  :timeout,
                  :sleeper

      def aguardar(start_date, end_date)
        limite = timeout

        while limite.positive?
          sleeper.call(POLL_INTERVAL)

          limite -= POLL_INTERVAL

          encontrado = encontrar(start_date, end_date)

          return encontrado if encontrado
        end

        raise ReportPending,
              "O relatório de liberações de #{start_date} a #{end_date} ainda está sendo gerado " \
              "pelo Mercado Pago. A próxima execução o encontra pronto."
      end

      # A lista traz begin_date/end_date do período pedido; casamos pela data,
      # não pelo nome do arquivo, que carrega o instante da geração.
      def encontrar(start_date, end_date)
        relatorios.find do |relatorio|
          mesma_data?(relatorio["begin_date"], start_date) &&
            mesma_data?(relatorio["end_date"], end_date)
        end
      end

      def mesma_data?(valor, data)
        Date.parse(valor.to_s) == data.to_date
      rescue Date::Error, TypeError
        false
      end

      def iso(data, fim_do_dia: false)
        hora = fim_do_dia ? "23:59:59" : "00:00:00"

        "#{data.to_date.strftime('%Y-%m-%d')}T#{hora}Z"
      end

      def get(path)
        JSON.parse(corpo(get_raw(path)).presence || "[]")
      rescue JSON::ParserError
        raise Error, "Resposta não-JSON do relatório de liberações"
      end

      def get_raw(path)
        executar(Net::HTTP::Get.new(URI.join(api_host, path)))
      end

      def post(path, **body)
        requisicao = Net::HTTP::Post.new(URI.join(api_host, path))

        requisicao["Content-Type"] = "application/json"

        requisicao.body = body.to_json

        executar(requisicao)
      end

      def api_host
        ENV["MP_API_HOST"].presence || "https://api.mercadopago.com"
      end

      def executar(requisicao)
        requisicao["Authorization"] = "Bearer #{access_token}"

        requisicao["Accept"] = "application/json"

        uri = requisicao.uri

        RedeExterna.bloquear!("o relatório de liberações do Mercado Pago")


        http = Net::HTTP.new(uri.host, uri.port)

        http.use_ssl = uri.scheme == "https"

        http.open_timeout = OPEN_TIMEOUT

        http.read_timeout = READ_TIMEOUT

        verificar!(http.request(requisicao))
      rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNRESET => e
        raise Error, "Falha de rede no relatório de liberações: #{e.class} #{e.message}"
      end

      def verificar!(resposta)
        codigo = resposta.code.to_i

        raise AuthError, "Token do Mercado Pago inválido ou expirado" if [401, 403].include?(codigo)

        raise RateLimited, "Bloqueio por excesso de requisições (429)" if codigo == 429

        # 202 é o retorno normal da criação: aceito, gerando.
        return resposta if resposta.is_a?(Net::HTTPSuccess)

        raise Error, "Relatório de liberações respondeu HTTP #{codigo}"
      end

      def corpo(resposta) = resposta.body.to_s
    end
  end
end
