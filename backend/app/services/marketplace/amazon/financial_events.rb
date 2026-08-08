module Marketplace
  module Amazon
    # Converte os eventos financeiros da SP-API em lançamentos do ledger.
    #
    # A resposta traz quase 30 listas de eventos. Aqui tratamos as que compõem o
    # resultado financeiro do vendedor; as demais são contadas em `ignorados`
    # para que uma lista relevante que apareça não passe despercebida.
    #
    # Convenção de sinal da Amazon: cobranças vêm positivas e taxas negativas.
    # Em vez de presumir a direção pelo tipo, ela é derivada do sinal — assim um
    # estorno de taxa (positivo) entra como crédito naturalmente.
    class FinancialEvents
      SOURCE = :amazon

      PAGE_SIZE = 100

      MAX_PAGES = 100

      # lista => [prefixo do external_id, entry_type]
      LISTAS = {
        "ShipmentEventList" => ["SHIP", :sale],
        "RefundEventList" => ["REFUND", :refund],
        "ChargebackEventList" => ["CHARGEBACK", :chargeback],
        "GuaranteeClaimEventList" => ["CLAIM", :dispute],
        "ServiceFeeEventList" => ["SERVICEFEE", :fee],
        "AdjustmentEventList" => ["ADJ", :adjustment],
        "ProductAdsPaymentEventList" => ["ADS", :fee]
      }.freeze

      # Listas com AmazonOrderId + ShipmentItemList (mesma forma do ShipmentEvent).
      COM_ITENS = %w[
        ShipmentEventList
        RefundEventList
        ChargebackEventList
        GuaranteeClaimEventList
      ].freeze

      def initialize(client:)
        @client = client

        @ignorados = Hash.new(0)
      end

      attr_reader :ignorados

      def call(start_date:, end_date:)
        brutos = []

        each_page(start_date, end_date) do |financial_events|
          brutos.concat(extrair(financial_events))
        end

        registrar_ignorados

        agregar(brutos)
      end

      private

      attr_reader :client

      def each_page(start_date, end_date)
        token = nil

        MAX_PAGES.times do |pagina|
          resposta = client.get(
            Settings.path(:financial_events),
            MaxResultsPerPage: PAGE_SIZE,
            PostedAfter: start_date.to_time.utc.iso8601,
            PostedBefore: end_date.to_time.utc.end_of_day.iso8601,
            NextToken: token
          )

          corpo = resposta["payload"] || resposta

          yield(corpo["FinancialEvents"] || {})

          token = corpo["NextToken"].presence

          break if token.blank?

          if pagina == MAX_PAGES - 1
            Rails.logger.warn(
              "[Amazon] janela truncada em #{MAX_PAGES} páginas — há mais eventos não lidos"
            )
          end
        end
      end

      def extrair(financial_events)
        financial_events.flat_map do |nome, eventos|
          next [] if eventos.blank?

          config = LISTAS[nome]

          if config.blank?
            @ignorados[nome] += Array(eventos).size

            next []
          end

          prefixo, tipo = config

          Array(eventos).flat_map { |evento| linhas_de(nome, prefixo, tipo, evento) }
        end
      end

      def linhas_de(nome, prefixo, tipo, evento)
        return itens_de(prefixo, tipo, evento) if COM_ITENS.include?(nome)

        return taxa_de_servico(prefixo, evento) if nome == "ServiceFeeEventList"

        return ajuste(prefixo, tipo, evento) if nome == "AdjustmentEventList"

        valor_simples(prefixo, tipo, evento)
      end

      def itens_de(prefixo, tipo, evento)
        pedido = evento["AmazonOrderId"]

        data = evento["PostedDate"]

        Array(evento["ShipmentItemList"]).flat_map do |item|
          cobrancas = Array(item["ItemChargeList"]).map do |c|
            linha(prefixo, tipo, pedido, data, c["ChargeType"], c["ChargeAmount"])
          end

          taxas = Array(item["ItemFeeList"]).map do |f|
            linha("#{prefixo}FEE", :fee, pedido, data, f["FeeType"], f["FeeAmount"])
          end

          cobrancas + taxas
        end
      end

      def taxa_de_servico(prefixo, evento)
        pedido = evento["AmazonOrderId"]

        Array(evento["FeeList"]).map do |f|
          linha(prefixo, :fee, pedido, evento["PostedDate"], f["FeeType"] || evento["FeeReason"], f["FeeAmount"])
        end
      end

      def ajuste(prefixo, tipo, evento)
        [
          linha(prefixo, tipo, nil, evento["PostedDate"], evento["AdjustmentType"], evento["AdjustmentAmount"])
        ]
      end

      def valor_simples(prefixo, tipo, evento)
        valor = evento["TransactionAmount"] || evento["ChargeAmount"] || evento["BaseValue"]

        return [] if valor.blank?

        [linha(prefixo, tipo, evento["AmazonOrderId"], evento["PostedDate"], prefixo, valor)]
      end

      def linha(prefixo, tipo, pedido, data, rotulo, moeda)
        valor = (moeda || {})["CurrencyAmount"].to_d

        {
          chave: [prefixo, pedido, data, rotulo].compact.join("-"),
          prefixo: prefixo,
          entry_type: tipo,
          pedido: pedido,
          data: data,
          rotulo: rotulo,
          moeda: (moeda || {})["CurrencyCode"],
          valor: valor
        }
      end

      # Um pedido pode ter várias linhas do mesmo tipo; somar por chave mantém o
      # external_id estável e a ingestão idempotente.
      def agregar(linhas)
        linhas.group_by { |l| l[:chave] }.map do |chave, grupo|
          total = grupo.sum(BigDecimal("0")) { |l| l[:valor] }

          base = grupo.first

          {
            external_id: "AMZ-#{chave}",

            external_order_id: base[:pedido],

            source: SOURCE,

            entry_type: base[:entry_type],

            direction: total.negative? ? :debit : :credit,

            amount: total.abs,

            occurred_at: base[:data],

            available_on: nil,

            raw_payload: {
              "origem" => "sp_api_financial_events",
              "tipo_amazon" => base[:rotulo],
              "prefixo" => base[:prefixo],
              "moeda" => base[:moeda],
              "linhas" => grupo.size,
              "total" => total.to_s
            }
          }
        end
      end

      def registrar_ignorados
        return if ignorados.empty?

        Rails.logger.info "[Amazon] listas de evento não tratadas: #{ignorados.inspect}"
      end
    end
  end
end
