require "net/http"
require "json"

module Marketplace
  module MercadoLivre
    # Pedidos do vendedor no Mercado Livre.
    #
    # Existe por causa de um elo que faltava. O relatório de liberações — a
    # fonte do dinheiro — identifica cada linha pelo SOURCE_ID, que é o id do
    # PAGAMENTO no Mercado Pago; a coluna PURCHASE_ID vem vazia em todas elas.
    # As notas do Tiny, por outro lado, trazem o número do PEDIDO. Sem alguém
    # que ligue pagamento a pedido, o dinheiro e a nota fiscal nunca se
    # encontram, e a conciliação contra o OMIE não tem por onde casar.
    #
    # Cada pedido daqui traz a lista de pagamentos dele, e é esse o elo. Uma
    # consulta por PÁGINA de pedidos, e não uma por pagamento: com centenas de
    # vendas, a diferença é entre minutos e horas.
    class OrdersClient
      PAGE_SIZE = 50

      # Teto de segurança, não meta.
      #
      # Era 50 páginas — 2500 pedidos —, o que parecia folgado para 30 dias.
      # Com dado real são ~43 pedidos por dia, e a janela dos pedidos recua 60
      # dias além da do extrato para alcançar as vendas que só liberam agora:
      # 90 dias já passam de 3800 pedidos. O laço para sozinho no total que o
      # Mercado Livre informa; isto aqui só impede laço infinito.
      MAX_PAGES = 400

      OPEN_TIMEOUT = 5

      READ_TIMEOUT = 30

      MAX_ATTEMPTS = 3

      class Error < StandardError; end

      class AuthError < Error
        include Marketplace::CredencialRecusada
      end

      class RateLimited < Error
        include Marketplace::LimiteDeRequisicoes
      end

      def initialize(access_token:, seller_id:, sleeper: nil)
        @access_token = access_token

        @seller_id = seller_id

        @sleeper = sleeper || ->(segundos) { sleep(segundos) }
      end

      # => [{ external_id:, pagamentos: [ids], status:, total:, criado_em:,
      #       comprador: }]
      def orders(start_date:, end_date:)
        # Sem o id do vendedor a consulta sai perguntando "os pedidos de quem?"
        # e volta 403 — que é indistinguível de falta de permissão.
        if seller_id.blank?
          raise Error,
                "A conta de marketplace não tem o id do vendedor no Mercado Livre. " \
                "Reconecte a conta em Integrações: é o OAuth que traz esse id."
        end

        coletados = []

        offset = 0

        MAX_PAGES.times do
          pagina = buscar(offset: offset, start_date: start_date, end_date: end_date)

          resultados = pagina["results"] || []

          break if resultados.empty?

          coletados.concat(resultados.map { |pedido| normalizar(pedido) })

          offset += PAGE_SIZE

          break if offset >= pagina.dig("paging", "total").to_i
        end

        coletados
      end

      # Um pedido só, pelo id.
      #
      # A busca por período não serve para investigar um caso: o pedido pode
      # estar fora da janela, e trazer 50 páginas para olhar um é desperdício.
      # É por aqui que se descobre o `pack_id` de uma venda específica.
      def order(id)
        normalizar(parse!(com_retry(URI.join(api_host, "/orders/#{id}"))))
      end

      # A resposta CRUA de um pedido.
      #
      # `normalizar` guarda só o que a ingestão usa, e para investigar é
      # preciso ver o resto — foi assim que o `pack_id` passou despercebido.
      def order_raw(id)
        parse!(com_retry(URI.join(api_host, "/orders/#{id}")))
      end

      # Dados fiscais do comprador.
      #
      # O Mercado Livre parou de devolver o documento dentro do pedido, mas o
      # mantém aqui — é o que o vendedor precisa para emitir a nota. Endpoint
      # separado, resposta com formato próprio.
      def billing_info(id)
        parse!(com_retry(URI.join(api_host, "/orders/#{id}/billing_info")))
      end

      private

      attr_reader :access_token, :seller_id, :sleeper

      def normalizar(pedido)
        {
          external_id: pedido["id"].to_s,
          # O id do PACOTE, quando a compra levou mais de um item.
          #
          # O Tiny registra o pack em `numero_ecommerce`, porque a nota fiscal
          # é do pacote — enquanto o extrato e esta API falam do pedido
          # individual. Jogar isto fora fazia a nota e o dinheiro da mesma
          # compra nunca se encontrarem.
          pack_id: pedido["pack_id"].to_s.presence,
          # Um pedido pode ter mais de um pagamento (parcelado em dois cartões,
          # retentativa depois de recusa). Todos apontam para o mesmo pedido.
          pagamentos: Array(pedido["payments"]).filter_map { |p| p["id"].to_s.presence },
          status: pedido["status"].to_s.presence,
          total: pedido["total_amount"],
          criado_em: pedido["date_created"],
          comprador: pedido.dig("buyer", "nickname")
        }
      end

      def buscar(offset:, start_date:, end_date:)
        uri = URI.join(api_host, "/orders/search")

        uri.query = URI.encode_www_form(
          seller: seller_id,
          "order.date_created.from": iso(start_date.to_date.beginning_of_day),
          "order.date_created.to": iso(end_date.to_date.end_of_day),
          sort: "date_asc",
          offset: offset,
          limit: PAGE_SIZE
        )

        parse!(com_retry(uri))
      end

      def iso(instante) = instante.utc.strftime("%Y-%m-%dT%H:%M:%S.000-00:00")

      def api_host = ENV["ML_API_HOST"].presence || "https://api.mercadolibre.com"

      def com_retry(uri)
        tentativa = 0

        begin
          tentativa += 1

          resposta = executar(uri)

          raise RateLimited, "Bloqueio por excesso de requisições (429)" if resposta.code.to_i == 429

          resposta
        rescue RateLimited, Net::OpenTimeout, Net::ReadTimeout, SocketError, Errno::ECONNRESET => e
          raise if tentativa >= MAX_ATTEMPTS

          # O 429 do Mercado Livre é por IP e pede espera bem maior do que uma
          # falha de rede comum.
          sleeper.call((e.is_a?(RateLimited) ? 15 : 2) * (2**(tentativa - 1)))

          retry
        end
      end

      def executar(uri)
        RedeExterna.bloquear!("os pedidos do Mercado Livre")

        http = Net::HTTP.new(uri.host, uri.port)

        http.use_ssl = uri.scheme == "https"

        http.open_timeout = OPEN_TIMEOUT

        http.read_timeout = READ_TIMEOUT

        requisicao = Net::HTTP::Get.new(uri)

        requisicao["Authorization"] = "Bearer #{access_token}"

        requisicao["Accept"] = "application/json"

        http.request(requisicao)
      end

      # 401 e 403 têm causas diferentes aqui, e chamar as duas de "token
      # inválido ou expirado" mandou a investigação para o lado errado: o mesmo
      # token estava funcionando no relatório de liberações, que é outra API
      # (api.mercadopago.com) e não depende de escopo de leitura de pedidos.
      #
      # 401 é o token não valer mais. 403 costuma ser o app não ter permissão
      # de LEITURA, ou o `seller` da consulta não ser o dono do token. As duas
      # se resolvem reconectando — mas por motivos diferentes, e quem lê
      # precisa saber qual conferir.
      def parse!(resposta)
        codigo = resposta.code.to_i

        detalhe = resposta.body.to_s.strip.truncate(200)

        raise AuthError, "O Mercado Livre não valeu mais o token (401): #{detalhe}" if codigo == 401

        if codigo == 403
          raise AuthError,
                "O Mercado Livre recusou a leitura dos pedidos do vendedor #{seller_id} (403). " \
                "Costuma ser o aplicativo sem permissão de leitura, ou a conta conectada não " \
                "ser a dona desses pedidos. Resposta: #{detalhe}"
        end

        unless resposta.is_a?(Net::HTTPSuccess)
          raise Error, "Pedidos do Mercado Livre responderam HTTP #{codigo}: " \
                       "#{resposta.body.to_s.strip.truncate(200)}"
        end

        JSON.parse(resposta.body.to_s)
      rescue JSON::ParserError
        raise Error, "Resposta não-JSON dos pedidos (HTTP #{resposta.code})"
      end
    end
  end
end
