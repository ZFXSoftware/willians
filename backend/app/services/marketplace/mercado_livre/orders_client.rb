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

      # Teto de segurança: 50 páginas são 2500 pedidos numa janela de 30 dias.
      MAX_PAGES = 50

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

      private

      attr_reader :access_token, :seller_id, :sleeper

      def normalizar(pedido)
        {
          external_id: pedido["id"].to_s,
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

      def parse!(resposta)
        codigo = resposta.code.to_i

        raise AuthError, "Token do Mercado Livre inválido ou expirado" if [ 401, 403 ].include?(codigo)

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
