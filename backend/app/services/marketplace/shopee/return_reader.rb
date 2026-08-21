module Marketplace
  module Shopee
    # Lê as devoluções e disputas da loja (get_return_list).
    #
    # Alimenta o briefing 2.8 com o registro que a própria Shopee mantém — bem
    # mais rico do que deduzir da movimentação financeira: traz o motivo, o
    # estado da negociação, o prazo do vendedor e, o que mais importa, o
    # `order_sn` de origem.
    #
    # Mesmas duas restrições da carteira: janela de 15 dias e paginação a
    # partir de zero. Campos conferidos na referência da API v2 (2026-08-21).
    class ReturnReader
      PAGE_SIZE = 100

      MAX_PAGINAS = 200

      # ReturnStatus da Shopee mapeado para o que interessa ao nosso rastro:
      # o caso ainda está em aberto ou já terminou?
      ENCERRADOS = %w[CANCELLED CLOSED REFUND_PAID SELLER_DISPUTE_SUCCESS].freeze

      def initialize(client:)
        @client = client
      end

      # => [{ return_sn:, order_sn:, valor:, motivo:, status:, ... }]
      def call(start_date:, end_date:)
        Janelas.quebrar(start_date, end_date).flat_map do |de, ate|
          coletar(de, ate)
        end.map { |registro| normalizar(registro) }
      end

      private

      attr_reader :client

      def coletar(de, ate)
        coletadas = []

        pagina = 0

        loop do
          resposta = client.get(:return_list,
                                page_no: pagina,
                                page_size: PAGE_SIZE,
                                create_time_from: de.beginning_of_day.to_i,
                                create_time_to: ate.end_of_day.to_i)

          corpo = resposta["response"] || {}

          coletadas.concat(Array(corpo["return"]))

          break unless corpo["more"]

          pagina += 1

          if pagina > MAX_PAGINAS
            Rails.logger.warn "[Shopee] varredura de devoluções truncada em #{MAX_PAGINAS} páginas"

            break
          end
        end

        coletadas
      end

      def normalizar(registro)
        status = registro["status"].to_s.strip.upcase

        {
          return_sn: registro["return_sn"].to_s.presence,
          order_sn: registro["order_sn"].to_s.presence,
          valor: registro["refund_amount"].to_d,
          moeda: registro["currency"].presence || "BRL",
          status: status,
          encerrado: ENCERRADOS.include?(status),
          # A Shopee pode reavaliar o motivo depois de ver as provas; quando
          # reavalia, é esse que vale.
          motivo: motivo(registro),
          motivo_livre: registro["text_reason"].presence,
          disputa: Array(registro["dispute_reason"]).reject { |r| r.to_s.casecmp?("UNKNOWN") }.presence,
          negociacao: registro["negotiation_status"].presence,
          prazo_do_vendedor: hora(registro["return_seller_due_date"]),
          aberta_em: hora(registro["create_time"]),
          atualizada_em: hora(registro["update_time"]),
          # 0 = devolve e reembolsa; 1 = só reembolsa (sem mercadoria de volta).
          devolve_mercadoria: registro["return_solution"].to_i.zero?,
          rastreio: registro["tracking_number"].presence
        }
      end

      def motivo(registro)
        reavaliado = registro["reassessed_request_reason"].to_s.strip

        return reavaliado if reavaliado.present? && !reavaliado.casecmp?("NONE")

        registro["reason"].presence
      end

      def hora(timestamp)
        return if timestamp.blank?

        Time.zone.at(timestamp.to_i)
      rescue TypeError, RangeError
        nil
      end
    end
  end
end
