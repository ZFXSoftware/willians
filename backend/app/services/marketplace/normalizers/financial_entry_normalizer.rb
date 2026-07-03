module Marketplace
  module Normalizers
    class FinancialEntryNormalizer
      def initialize(source:, payload:)
        @source = source
        @payload = payload
      end

      def call
        {
          external_id: external_id,

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
        payload["id"]
      end

      def amount
        payload["amount"].to_d
      end

      def occurred_at
        payload["created_at"]
      end

      def available_on
        payload["available_on"]
      end

      def entry_type
        case payload["type"]
        when "SALE"
          :sale

        when "FEE"
          :fee

        when "REFUND"
          :refund

        when "CHARGEBACK"
          :chargeback

        else
          :unidentified
        end
      end

      def direction
        case entry_type
        when :sale
          :credit

        when :refund,
             :chargeback,
             :fee
          :debit

        else
          :debit
        end
      end
    end
  end
end