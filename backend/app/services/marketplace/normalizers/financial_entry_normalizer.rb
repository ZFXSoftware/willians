module Marketplace
  module Normalizers
    class FinancialEntryNormalizer
      TYPE_MAP = {
        "SALE" => :sale,
        "PAYMENT" => :sale,
        "FEE" => :fee,
        "SHIPPING" => :fee,
        "REFUND" => :refund,
        "CHARGEBACK" => :chargeback,
        "DISPUTE" => :dispute,
        "SETTLEMENT" => :settlement,
        "PAYOUT" => :settlement
      }.freeze

      CREDIT_TYPES = %i[sale settlement].freeze

      DEBIT_TYPES = %i[fee refund chargeback dispute].freeze

      def initialize(source:, payload:)
        @source = source
        @payload = payload
      end

      def call
        {
          external_id: external_id,

          external_order_id: external_order_id,

          source: source,

          entry_type: entry_type,

          direction: direction,

          amount: amount,

          occurred_at: occurred_at,

          available_on: available_on,

          raw_payload: payload
        }
      end

      private

      attr_reader :source,
                  :payload

      def external_id
        payload["id"].presence&.to_s
      end

      def external_order_id
        (payload["order_id"] || payload["source_id"])
          .presence
          &.to_s
      end

      # O ledger guarda valor positivo + direção; o sinal vindo do marketplace
      # serve só para inferir a direção quando o tipo é desconhecido.
      def amount
        raw_amount.abs
      end

      def raw_amount
        payload["amount"].to_d
      end

      def occurred_at
        payload["created_at"] || payload["date_created"]
      end

      def available_on
        payload["available_on"] || payload["money_release_date"]
      end

      def entry_type
        TYPE_MAP.fetch(payload["type"].to_s.upcase, :unidentified)
      end

      def direction
        return :credit if CREDIT_TYPES.include?(entry_type)

        return :debit if DEBIT_TYPES.include?(entry_type)

        raw_amount.negative? ? :debit : :credit
      end
    end
  end
end
