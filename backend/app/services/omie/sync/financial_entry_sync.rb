module Omie
  module Sync
    class FinancialEntrySync
      ENDPOINT = "financas/contareceber/".freeze

      CALL = "IncluirContaReceber".freeze

      def initialize(financial_entry:, client: nil)
        @financial_entry = financial_entry

        @client = client
      end

      def call
        return existing_mapping if already_synced?

        response = client.request(ENDPOINT, CALL, payload)

        persist_mapping!(response)
      end

      private

      attr_reader :financial_entry

      def client
        @client ||=
          Omie::Client.configured? ? Omie::Client.new : Omie::FakeOmieClient.new
      end

      def already_synced?
        existing_mapping&.synced?
      end

      def existing_mapping
        @existing_mapping ||= financial_entry.omie_financial_mapping
      end

      def payload
        @payload ||=
          Omie::Mappers::FinancialEntryMapper
            .new(financial_entry: financial_entry)
            .call
      end

      def persist_mapping!(response)
        mapping =
          existing_mapping ||
          OmieFinancialMapping.new(
            tenant_id: financial_entry.tenant_id,
            financial_entry: financial_entry
          )

        mapping.update!(
          omie_financial_id:
            response["codigo_lancamento_omie"].to_s.presence,

          omie_category_id:
            payload[:codigo_categoria],

          synced: true,

          synced_at: Time.current,

          metadata: {
            payload_sent: payload,
            payload_received: response
          }
        )

        mapping
      end
    end
  end
end
