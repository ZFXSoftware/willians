module Omie
  module Sync
    class FinancialEntrySync
      def initialize(financial_entry:)
        @financial_entry =
          financial_entry
      end

      def call
        response =
          client.request(
            "/financas/contareceber/",

            "IncluirContaReceber",

            mapper.call
          )

        persist_mapping!(response)

        response
      end

      private

      attr_reader :financial_entry

      def client
        @client ||=
          OmieClient.new(
            app_key:
              ENV.fetch("OMIE_APP_KEY"),

            app_secret:
              ENV.fetch("OMIE_APP_SECRET")
          )
      end

      def mapper
        @mapper ||=
          Omie::Mappers::FinancialEntryMapper
            .new(
              financial_entry:
                financial_entry
            )
      end

      def persist_mapping!(response)
        OmieFinancialMapping.create!(
          financial_entry:
            financial_entry,

          omie_id:
            response[
              "codigo_lancamento_omie"
            ],

          payload_sent:
            mapper.call,

          payload_received:
            response,

          synced_at:
            Time.current
        )
      end
    end
  end
end