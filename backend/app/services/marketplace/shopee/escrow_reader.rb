module Marketplace
  module Shopee
    # Percorre os pedidos liquidados no período e traz a quebra financeira de
    # cada um.
    #
    # São duas chamadas encadeadas, conferidas na referência da API v2:
    #
    #   get_escrow_list   release_time_from/to (timestamp), page_no, page_size
    #                     -> order_sn, payout_amount, escrow_release_time
    #   get_escrow_detail order_sn -> a quebra completa
    #
    # A lista é paginada por `more`, e não por total de páginas. O filtro é
    # pela data de LIBERAÇÃO do dinheiro, que é o que interessa para conciliar:
    # o pedido pode ser de semanas antes.
    class EscrowReader
      PAGE_SIZE = 100

      MAX_PAGINAS = 200

      # Um pedido que falha não pode derrubar o período inteiro.
      Resultado = Struct.new(:eventos, :pedidos, :divergentes, :falhas, keyword_init: true)

      def initialize(client:)
        @client = client
      end

      def call(start_date:, end_date:)
        eventos = []

        divergentes = []

        falhas = []

        pedidos = listar(start_date, end_date)

        pedidos.each do |pedido|
          resultado = detalhar(pedido)

          next falhas << resultado[:falha] if resultado[:falha]

          eventos.concat(resultado[:eventos])

          divergentes << resultado[:divergencia] if resultado[:divergencia]
        end

        Resultado.new(eventos: eventos, pedidos: pedidos.size,
                      divergentes: divergentes, falhas: falhas)
      end

      # => [{ order_sn:, payout_amount:, liberado_em: }]
      def listar(start_date, end_date)
        coletados = []

        pagina = 1

        loop do
          resposta = client.get(:escrow_list,
                                release_time_from: inicio(start_date),
                                release_time_to: fim(end_date),
                                page_size: PAGE_SIZE,
                                page_no: pagina)

          corpo = resposta["response"] || {}

          Array(corpo["escrow_list"]).each do |item|
            coletados << {
              order_sn: item["order_sn"].to_s,
              payout_amount: item["payout_amount"].to_d,
              liberado_em: hora(item["escrow_release_time"])
            }
          end

          # A paginação é por `more`, não por total de páginas.
          break unless corpo["more"]

          pagina += 1

          if pagina > MAX_PAGINAS
            Rails.logger.warn "[Shopee] varredura de escrow truncada em #{MAX_PAGINAS} páginas"

            break
          end
        end

        coletados
      end

      private

      attr_reader :client

      def detalhar(pedido)
        resposta = client.get(:escrow_detail, order_sn: pedido[:order_sn])

        leitor = EscrowEvents.new(resposta, liberado_em: pedido[:liberado_em])

        eventos = leitor.call

        # A fórmula do escrow_amount é pública, então a decomposição pode se
        # conferir. Não fechando, o pedido é reportado em vez de virar
        # lançamento errado no razão.
        divergencia =
          unless leitor.confere?
            { order_sn: pedido[:order_sn], diferenca: leitor.diferenca }
          end

        { eventos: divergencia ? [] : eventos, divergencia: divergencia }
      rescue Client::Error => e
        { falha: { order_sn: pedido[:order_sn], erro: e.message } }
      end

      # A Shopee espera timestamp Unix.
      def inicio(data) = data.to_date.beginning_of_day.to_i

      def fim(data) = data.to_date.end_of_day.to_i

      def hora(timestamp)
        return if timestamp.blank?

        Time.zone.at(timestamp.to_i)
      rescue TypeError, RangeError
        nil
      end
    end
  end
end
