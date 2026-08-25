require "net/http"
require "json"
require "time"

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

      class AuthError < Error
        include Marketplace::CredencialRecusada
      end

      class RateLimited < Error
        include Marketplace::LimiteDeRequisicoes
      end

      # O relatório não ficou pronto dentro da janela de espera. Não é falha:
      # a próxima execução encontra o arquivo pronto.
      class ReportPending < Error
        include Marketplace::AindaNaoPronto
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
        post(BASE_PATH,
             begin_date: iso(inicio_instante(start_date)),
             end_date: iso(fim_instante(end_date)))
      end

      # Devolve [] quando não reconhece o formato — e isso é indistinguível de
      # "nenhum relatório existe". Como quem chama fica esperando o arquivo
      # aparecer nessa lista, o formato inesperado viraria espera eterna sem
      # uma linha sequer no log.
      def relatorios
        resposta = get("#{BASE_PATH}/list")

        return resposta if resposta.is_a?(Array)

        lista = resposta.is_a?(Hash) ? resposta["results"] : nil

        return lista if lista.is_a?(Array)

        Rails.logger.warn(
          "[ReleasesClient] a lista de relatórios veio num formato não previsto " \
          "(#{resposta.class}#{", chaves: #{resposta.keys.join(', ')}" if resposta.is_a?(Hash)}). " \
          "Tratando como vazia — é isto que faz a espera nunca terminar."
        )

        []
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

        # Diz o que a lista TINHA. "Ainda sendo gerado" é uma leitura otimista
        # de "não achei o meu ali dentro" — e as duas se parecem até alguém
        # comparar os períodos que voltaram com o período pedido.
        Rails.logger.warn(
          "[ReleasesClient] desisti de esperar o relatório de #{start_date} a #{end_date}. " \
          "A lista do Mercado Pago tem #{disponiveis.size} relatório(s): " \
          "#{disponiveis.empty? ? 'nenhum' : disponiveis.join(' | ')}"
        )

        raise ReportPending,
              "O relatório de liberações de #{start_date} a #{end_date} ainda está sendo gerado " \
              "pelo Mercado Pago. A próxima execução o encontra pronto."
      end

      # Os períodos que a lista devolveu, para conferir contra o que pedimos.
      def disponiveis
        relatorios.first(10).map do |relatorio|
          "#{relatorio['begin_date']}..#{relatorio['end_date']}"
        end
      rescue StandardError => e
        [ "(não deu para listar: #{e.class})" ]
      end

      # O Mercado Pago NÃO devolve o período que pedimos.
      #
      # Pedimos 2026-07-26T00:00:00Z..2026-08-25T14:00:00Z e a lista traz
      # 2026-07-25T03:00:00Z..2026-08-26T02:59:59Z — que é 2026-07-25 00:00 a
      # 2026-08-25 23:59:59 no fuso da conta (BRT, UTC-3). Ele converte para o
      # horário local e arredonda para dias INTEIROS.
      #
      # Casar por igualdade de data nunca dava certo. Como o relatório nunca
      # era encontrado, cada tentativa mandava gerar outro: a conta do cliente
      # acumulou dez relatórios idênticos e a espera não terminava nunca.
      #
      # O arredondamento só ALARGA a janela — piso e teto de dia local caem
      # sempre fora do que foi pedido, em qualquer fuso. Então o critério é
      # CONTER, o que dispensa saber qual é o fuso da conta.
      def encontrar(start_date, end_date)
        inicio = inicio_instante(start_date)

        fim = fim_instante(end_date)

        # Entre os que servem, o mais justo: sem isso um relatório de um ano
        # atenderia um pedido de trinta dias, e baixaríamos o ano inteiro.
        relatorios
          .select { |relatorio| cobre?(relatorio, inicio, fim) }
          .min_by { |relatorio| duracao(relatorio) }
      end

      def cobre?(relatorio, inicio, fim)
        de = instante(relatorio["begin_date"])

        ate = instante(relatorio["end_date"])

        return false if de.nil? || ate.nil?

        de <= inicio && ate >= fim
      end

      def duracao(relatorio)
        de = instante(relatorio["begin_date"])

        ate = instante(relatorio["end_date"])

        de && ate ? ate - de : Float::INFINITY
      end

      def instante(valor)
        Time.parse(valor.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      def inicio_instante(data)
        data.to_date.beginning_of_day
      end

      # O fim do dia de HOJE está no futuro, e relatório do que ainda não
      # aconteceu não existe. Como a janela padrão da conciliação termina em
      # Date.current, esse era o pedido de todo dia.
      #
      # Sem fração de segundo: `end_of_day` é 23:59:59.999999999, o relatório
      # volta com 23:59:59, e a comparação "cobre o que pedi?" reprovava por
      # menos de um segundo — que é justamente a precisão que o `iso` descarta
      # ao mandar o pedido.
      def fim_instante(data)
        [ data.to_date.end_of_day, Time.current ].min.change(usec: 0)
      end

      def iso(instante)
        instante.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
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

        verificar!(http.request(requisicao), requisicao)
      rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNRESET => e
        raise Error, "Falha de rede no relatório de liberações: #{e.class} #{e.message}"
      end

      # Diz QUAL chamada falhou e o que o Mercado Pago respondeu.
      #
      # "Relatório de liberações respondeu HTTP 400" era um beco sem saída: o
      # fluxo faz três chamadas diferentes (listar, criar, baixar) e a
      # explicação do 400 vem justamente no corpo, que estava sendo descartado.
      def verificar!(resposta, requisicao = nil)
        codigo = resposta.code.to_i

        onde = requisicao ? "#{requisicao.method} #{requisicao.uri.path}" : "Relatório de liberações"

        raise AuthError, "#{onde}: token do Mercado Pago inválido ou expirado" if [ 401, 403 ].include?(codigo)

        raise RateLimited, "#{onde}: bloqueio por excesso de requisições (429)" if codigo == 429

        # 202 é o retorno normal da criação: aceito, gerando.
        return resposta if resposta.is_a?(Net::HTTPSuccess)

        raise Error, "#{onde} respondeu HTTP #{codigo}#{explicacao(resposta)}"
      end

      # O corpo do erro é texto do Mercado Pago sobre a NOSSA requisição (as
      # datas que mandamos), não sobre a credencial — o token vai em cabeçalho
      # e não é ecoado. Mesmo assim só vai para o log, nunca para a tela.
      def explicacao(resposta)
        corpo = resposta.body.to_s.strip

        corpo.empty? ? "" : " — #{corpo.truncate(300)}"
      end

      def corpo(resposta) = resposta.body.to_s
    end
  end
end
