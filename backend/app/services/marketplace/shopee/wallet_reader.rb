module Marketplace
  module Shopee
    # Percorre as movimentações da carteira no período.
    #
    # Duas restrições da API que moldam este código, ambas conferidas na
    # referência:
    #
    #   - a janela de consulta é de no MÁXIMO 15 dias, então um período maior
    #     é quebrado em pedaços;
    #   - a paginação começa em page_no = 0 (a de escrow_list começa em 1).
    #
    # Errar qualquer uma das duas devolve erro de parâmetro ou, pior, silêncio
    # com meia página.
    class WalletReader
      PAGE_SIZE = 100

      MAX_PAGINAS = 200

      Resultado = Struct.new(:eventos, :transacoes, :ignorados, :pendentes, :saldo,
                             keyword_init: true)

      def initialize(client:)
        @client = client
      end

      def call(start_date:, end_date:)
        transacoes = []

        janelas(start_date, end_date).each do |de, ate|
          transacoes.concat(coletar(de, ate))
        end

        leitor = WalletEvents.new(transacoes)

        Resultado.new(
          eventos: leitor.call,
          transacoes: transacoes.size,
          ignorados: leitor.ignorados,
          pendentes: leitor.pendentes,
          saldo: leitor.saldo
        )
      end

      # A API recusa período maior que 15 dias — ver Shopee::Janelas.
      def janelas(start_date, end_date) = Janelas.quebrar(start_date, end_date)

      private

      attr_reader :client

      def coletar(de, ate)
        coletadas = []

        # Começa em ZERO: diferente de escrow_list, que começa em 1.
        pagina = 0

        loop do
          resposta = client.get(:wallet_transactions,
                                page_no: pagina,
                                page_size: PAGE_SIZE,
                                create_time_from: de.beginning_of_day.to_i,
                                create_time_to: ate.end_of_day.to_i)

          corpo = resposta["response"] || {}

          coletadas.concat(Array(corpo["transaction_list"]))

          break unless corpo["more"]

          pagina += 1

          if pagina > MAX_PAGINAS
            Rails.logger.warn "[Shopee] varredura da carteira truncada em #{MAX_PAGINAS} páginas"

            break
          end
        end

        coletadas
      end
    end
  end
end
