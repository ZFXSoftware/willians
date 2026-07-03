module Omie
  module Sync
    class SettlementSync
      def initialize(financial_entry:)
        @financial_entry =
          financial_entry
      end

      def call
        return unless settlement?

        client.request(
          "/financas/contareceber/",

          "RegistrarRecebimento",

          request_payload
        )
      end

      private

      attr_reader :financial_entry

      def settlement?
        financial_entry.settlement?
      end

      def client
        @client ||=
          OmieClient.new(
            app_key:
              ENV.fetch("OMIE_APP_KEY"),

            app_secret:
              ENV.fetch("OMIE_APP_SECRET")
          )
      end

      def request_payload
        {
          codigo_lancamento_omie:
            omie_mapping.omie_id,

          valor_recebido:
            financial_entry.amount,

          data_recebimento:
            financial_entry.occurred_at
        }
      end

      def omie_mapping
        financial_entry
          .omie_financial_mapping
      end
    end
  end
end