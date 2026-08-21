require "net/http"
require "json"

module Fiscal
  module Tiny
    # API 2.0 do Tiny: POST form-encoded com o token no corpo, resposta JSON
    # embrulhada em `retorno`.
    #
    # Peculiaridade importante: o Tiny responde HTTP 200 mesmo em erro, e
    # sinaliza em `retorno.status`. Consulta sem resultado também chega como
    # "Erro" — mas é resultado vazio, não falha, e é tratada como tal.
    class V2Client
      OPEN_TIMEOUT = 5

      READ_TIMEOUT = 30

      MAX_ATTEMPTS = 3

      REGISTROS_POR_PAGINA = 100

      # Mensagens que significam "nada encontrado", não falha.
      SEM_REGISTROS = /não retornou registros|nenhum registro|not found/i

      class Error < StandardError; end

      class AuthError < Error; end

      class ApiError < Error
        attr_reader :codigo

        def initialize(message, codigo: nil)
          @codigo = codigo

          super(message)
        end
      end

      def initialize(token: nil)
        @token = token || Settings.token
      end

      # => { itens: [...], pagina:, total_paginas: }
      def pesquisar_notas(pagina: 1, data_inicial: nil, data_final: nil, numero_ecommerce: nil, tipo: "S")
        retorno = post(
          "notas.fiscais.pesquisa.php",
          pagina: pagina,
          tipoNota: tipo,
          dataInicial: formatar(data_inicial),
          dataFinal: formatar(data_final),
          numeroEcommerce: numero_ecommerce
        )

        return vazio(pagina) if retorno.nil?

        {
          itens: desembrulhar(retorno["notas_fiscais"], "nota_fiscal"),
          pagina: (retorno["pagina"] || pagina).to_i,
          total_paginas: (retorno["numero_paginas"] || 1).to_i
        }
      end

      private

      attr_reader :token

      def vazio(pagina)
        { itens: [], pagina: pagina, total_paginas: 0 }
      end

      # O Tiny devolve listas como [{ "nota_fiscal" => {...} }, ...].
      def desembrulhar(lista, chave)
        Array(lista).map { |item| item.is_a?(Hash) ? (item[chave] || item) : item }
      end

      def formatar(data)
        data&.to_date&.strftime("%d/%m/%Y")
      end

      def post(caminho, params)
        # Valida o token DESTA instância, não o do ambiente: o cliente precisa
        # funcionar com token injetado (testes, múltiplas contas no futuro).
        Settings.ensure_configured! if token.blank?

        uri = URI.join("#{Settings.v2_base}/", caminho)

        corpo = params.compact.merge(token: token, formato: "json")

        resposta = com_retry { executar(uri, corpo) }

        interpretar(resposta, caminho)
      end

      def com_retry
        attempt = 0

        begin
          attempt += 1

          yield
        rescue Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNRESET => e
          raise Error, "Falha de rede no Tiny: #{e.class} #{e.message}" if attempt >= MAX_ATTEMPTS

          sleep(2**(attempt - 1))

          retry
        end
      end

      def executar(uri, corpo)
        RedeExterna.bloquear!("o Tiny")

        http = Net::HTTP.new(uri.host, uri.port)

        http.use_ssl = true

        http.open_timeout = OPEN_TIMEOUT

        http.read_timeout = READ_TIMEOUT

        req = Net::HTTP::Post.new(uri)

        req["Content-Type"] = "application/x-www-form-urlencoded"

        req["Accept"] = "application/json"

        req.body = URI.encode_www_form(corpo)

        http.request(req)
      end

      # Devolve o `retorno` em sucesso, ou nil quando a consulta não achou nada.
      def interpretar(resposta, caminho)
        parsed = JSON.parse(resposta.body.to_s)

        retorno = parsed["retorno"] || parsed

        return retorno if retorno["status"].to_s.casecmp("ok").zero?

        mensagens = Array(retorno["erros"]).map { |e| e.is_a?(Hash) ? e["erro"] : e }.compact

        texto = mensagens.join("; ").presence || retorno["status"].to_s

        return nil if texto.match?(SEM_REGISTROS)

        raise AuthError, "Token do Tiny inválido: #{texto}" if texto.match?(/token/i)

        raise ApiError.new("Tiny recusou #{caminho}: #{texto}", codigo: retorno["codigo_erro"])
      rescue JSON::ParserError
        raise Error, "Resposta não-JSON do Tiny em #{caminho} (HTTP #{resposta.code})"
      end
    end
  end
end
