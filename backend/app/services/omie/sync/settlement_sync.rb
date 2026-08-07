module Omie
  module Sync
    # Baixa do título no OMIE.
    #
    # A chamada é `LancarRecebimento` (não existe `RegistrarRecebimento`) e os
    # campos são codigo_lancamento / codigo_conta_corrente / valor / data.
    class SettlementSync
      ENDPOINT = "financas/contareceber/".freeze

      CALL = "LancarRecebimento".freeze

      class MissingMapping < StandardError; end

      def initialize(financial_entry:, client: nil)
        @financial_entry = financial_entry

        @client = client
      end

      def call
        return unless financial_entry.settlement?

        raise MissingMapping, "Lançamento #{financial_entry.id} não tem título no OMIE" if omie_financial_id.blank?

        response = client.request(ENDPOINT, CALL, request_payload)

        record_settlement!(response)

        response
      end

      private

      attr_reader :financial_entry

      def client
        @client ||=
          Omie::Client.configured? ? Omie::Client.new : Omie::FakeOmieClient.new
      end

      def omie_financial_id
        omie_mapping&.omie_financial_id
      end

      def omie_mapping
        @omie_mapping ||= financial_entry.omie_financial_mapping
      end

      def settings
        @settings ||= Omie::Settings.for(financial_entry)
      end

      def request_payload
        {
          codigo_lancamento: omie_financial_id.to_i,

          codigo_conta_corrente: settings.conta_corrente_id,

          valor: financial_entry.amount.to_f,

          data: financial_entry.occurred_at&.to_date&.strftime("%d/%m/%Y"),

          observacao: "Baixa automática — #{financial_entry.external_id}"
        }
      end

      def record_settlement!(response)
        return if omie_mapping.blank?

        omie_mapping.update!(
          metadata: omie_mapping.metadata.merge(
            "baixa" => {
              "codigo_baixa" => response["codigo_baixa"],
              "registrada_em" => Time.current
            }
          )
        )
      end
    end
  end
end
