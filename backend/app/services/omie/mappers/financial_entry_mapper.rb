module Omie
  module Mappers
    class FinancialEntryMapper
      def initialize(financial_entry:)
        @financial_entry =
          financial_entry
      end

      def call
        {
          codigo_cliente:
            customer_code,

          data_vencimento:
            due_date,

          valor_documento:
            financial_entry.amount,

          observacao:
            description,

          codigo_categoria:
            category_code
        }
      end

      private

      attr_reader :financial_entry

      def customer_code
        "1"
      end

      def due_date
        financial_entry.available_on
      end

      def description
        [
          financial_entry.entry_type,
          financial_entry.external_id
        ].join(" - ")
      end

      def category_code
        case financial_entry.entry_type
        when "sale"
          "1.01.01"

        when "fee"
          "1.02.01"

        when "refund"
          "1.03.01"

        else
          "1.99.99"
        end
      end
    end
  end
end