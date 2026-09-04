require "net/http"
require "json"
require "base64"

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
        @token_informado = token
      end

      # Resolvido a cada uso, e não na construção — mesma razão do Omie::Client.
      #
      # O token vive na tela de Configurações, por EMPRESA, e o cliente costuma
      # ser montado antes de o tenant do contexto existir. Resolvendo cedo, ele
      # caía no ambiente (vazio) e o Tiny respondia "token invalido" para quem
      # tinha o token cadastrado — foi o que aconteceu no `tiny:importar`,
      # enquanto o `tiny:check`, que define o tenant antes, funcionava.
      def token
        @token_informado || Settings.token
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

      # A nota INTEIRA, pelo id do Tiny.
      #
      # A pesquisa é uma listagem e devolve um resumo — e para oito notas ela
      # traz `valor` como "0.00". Só a nota completa diz se o valor realmente
      # não existe ou se é a listagem que não o calcula: aqui vêm os itens e os
      # totais que o cabeçalho da busca não tem.
      #
      # => o hash da nota, ou nil quando o Tiny não a encontra.
      def obter_nota(id)
        retorno = post("nota.fiscal.obter.php", id: id)

        return if retorno.nil?

        nota = retorno["nota_fiscal"]

        nota.is_a?(Hash) ? nota : nil
      end

      # O XML da NF-e, como ela foi transmitida à SEFAZ.
      #
      # É a única forma de saber o que a nota carrega de verdade — o JSON do
      # Tiny é a visão DELE do documento, não o documento. A pergunta que isto
      # responde: o número do pedido no marketplace está dentro da NF-e, ou só
      # existe no ERP?
      #
      # => a string do XML, ou nil.
      def obter_xml(id)
        retorno = post("nota.fiscal.obter.xml.php", id: id)

        return if retorno.nil?

        bruto = retorno["xml_nfe"] || retorno.dig("nota_fiscal", "xml") || retorno["xml"]

        return if bruto.blank?

        # O Tiny devolve ora o XML cru, ora em base64. Reconhecer pelo conteúdo
        # é mais confiável que supor pelo campo.
        bruto.to_s.lstrip.start_with?("<") ? bruto : decodificar(bruto)
      end

      private

      def decodificar(texto)
        Base64.decode64(texto.to_s).force_encoding("UTF-8")
      rescue StandardError
        nil
      end

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
        corpo = resposta.body.to_s

        # O endpoint de XML responde o documento cru, sem envelope JSON. Sem
        # este desvio ele morreria em "resposta não-JSON", que é verdade e não
        # ajuda em nada.
        return { "status" => "OK", "xml_nfe" => corpo } if corpo.lstrip.start_with?("<")

        parsed = JSON.parse(corpo)

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
