module Marketplace
  module Amazon
    # Grupos de eventos financeiros da Amazon — o equivalente ao repasse.
    #
    #   GET /finances/v0/financialEventGroups
    #   MaxResultsPerPage (máx 100), FinancialEventGroupStartedAfter/Before
    #   (ISO 8601), NextToken
    #
    # Schema conferido no modelo oficial da SP-API (financesV0.json).
    #
    # A Amazon NÃO expõe saldo de carteira como o Mercado Pago e a Shopee. O
    # que existe é um ciclo: um grupo fica ABERTO acumulando o que o vendedor
    # tem a receber, e ao fechar o dinheiro é transferido para a conta
    # bancária. Então:
    #
    #   grupo fechado + FundTransferDate  ->  saque (briefing 2.7)
    #   grupo aberto                      ->  o que está por receber (2.4)
    #
    # Chamar isso de "saldo disponível" seria mentira: na Amazon não existe
    # dinheiro parado e sacável. Por isso o valor é reportado como FUTURO.
    class EventGroups
      PATH = "/finances/v0/financialEventGroups".freeze

      MAX_POR_PAGINA = 100

      MAX_PAGINAS = 50

      ABERTO = "Open".freeze

      # A transferência pode falhar ou ser cancelada; nesses casos não houve
      # saque. Como a documentação não enumera os valores, o teste é por
      # palavra — e o status vai para o metadata, para auditoria.
      NAO_TRANSFERIDO = /fail|cancel|reject|error/i

      Resultado = Struct.new(:saques, :aberto, :grupos, keyword_init: true)

      def initialize(client:)
        @client = client
      end

      def call(start_date:, end_date:)
        grupos = coletar(start_date, end_date)

        Resultado.new(
          saques: grupos.filter_map { |grupo| saque(grupo) },
          aberto: grupos.find { |grupo| grupo["ProcessingStatus"].to_s.casecmp?(ABERTO) },
          grupos: grupos.size
        )
      end

      # O que a Amazon tem a pagar no ciclo em curso.
      def self.a_receber(grupo)
        return if grupo.blank?

        valor = grupo.dig("OriginalTotal", "CurrencyAmount")

        # Um grupo recém-aberto pode não ter total ainda; o saldo inicial é o
        # que dá para afirmar.
        valor = grupo.dig("BeginningBalance", "CurrencyAmount") if valor.nil?

        return if valor.nil?

        {
          valor: BigDecimal(valor.to_s),
          moeda: grupo.dig("OriginalTotal", "CurrencyCode") ||
                 grupo.dig("BeginningBalance", "CurrencyCode") || "BRL",
          desde: hora(grupo["FinancialEventGroupStart"])
        }
      end

      def self.hora(valor)
        return if valor.blank?

        Time.zone.parse(valor.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      private

      attr_reader :client

      def coletar(start_date, end_date)
        grupos = []

        token = nil

        pagina = 0

        loop do
          params = {
            MaxResultsPerPage: MAX_POR_PAGINA,
            FinancialEventGroupStartedAfter: iso(start_date.to_date.beginning_of_day),
            FinancialEventGroupStartedBefore: iso(end_date.to_date.end_of_day)
          }

          params[:NextToken] = token if token.present?

          corpo = (client.get(PATH, params) || {})["payload"] || {}

          grupos.concat(Array(corpo["FinancialEventGroupList"]))

          token = corpo["NextToken"].presence

          break if token.blank?

          pagina += 1

          if pagina > MAX_PAGINAS
            Rails.logger.warn "[Amazon] varredura de grupos truncada em #{MAX_PAGINAS} páginas"

            break
          end
        end

        grupos
      end

      # Um grupo só é saque quando o dinheiro efetivamente saiu.
      def saque(grupo)
        transferido_em = self.class.hora(grupo["FundTransferDate"])

        return if transferido_em.blank?

        status = grupo["FundTransferStatus"].to_s

        return if status.match?(NAO_TRANSFERIDO)

        valor = grupo.dig("OriginalTotal", "CurrencyAmount")

        return if valor.nil?

        valor = BigDecimal(valor.to_s)

        return if valor.zero?

        {
          external_id: "AMZ-PAYOUT-#{grupo['FinancialEventGroupId']}",
          platform: "amazon",
          entry_type: :settlement,
          # Total negativo significa que a Amazon cobrou do vendedor no ciclo.
          direction: valor.negative? ? :credit : :debit,
          amount: valor.abs,
          currency: grupo.dig("OriginalTotal", "CurrencyCode") || "BRL",
          occurred_at: transferido_em,
          available_on: transferido_em.to_date,
          external_order_id: nil,
          description: "Transferência do ciclo #{grupo['FinancialEventGroupId']}",
          metadata: {
            "financial_event_group_id" => grupo["FinancialEventGroupId"],
            "fund_transfer_status" => status.presence,
            "processing_status" => grupo["ProcessingStatus"],
            "account_tail" => grupo["AccountTail"],
            "trace_id" => grupo["TraceId"],
            "ciclo_de" => grupo["FinancialEventGroupStart"],
            "ciclo_ate" => grupo["FinancialEventGroupEnd"]
          }.compact
        }
      end

      def iso(momento) = momento.utc.iso8601
    end
  end
end
