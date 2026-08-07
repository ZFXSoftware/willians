module Omie
  module Mappers
    # Monta o payload de IncluirContaReceber.
    #
    # Campos obrigatórios conforme a doc do OMIE: codigo_lancamento_integracao,
    # codigo_cliente_fornecedor, data_vencimento, valor_documento,
    # codigo_categoria, data_previsao e id_conta_corrente.
    class FinancialEntryMapper
      def initialize(financial_entry:)
        @financial_entry = financial_entry
      end

      def call
        @call ||= {
          # Chave do round-trip: é por ela que a conciliação reencontra o título
          # no OMIE depois.
          codigo_lancamento_integracao:
            financial_entry.external_id,

          codigo_cliente_fornecedor:
            settings.cliente_fornecedor_id,

          id_conta_corrente:
            settings.conta_corrente_id,

          data_vencimento:
            due_date,

          data_previsao:
            due_date,

          valor_documento:
            financial_entry.amount.to_f,

          observacao:
            description,

          codigo_categoria:
            category_code
        }
      end

      private

      attr_reader :financial_entry

      # Resolve cliente/conta/categoria pela conta de marketplace do lançamento,
      # caindo para o tenant e depois para o ambiente.
      def settings
        @settings ||= Omie::Settings.for(financial_entry)
      end

      def due_date
        (financial_entry.available_on || financial_entry.occurred_at&.to_date)
          &.strftime("%d/%m/%Y")
      end

      def description
        [
          financial_entry.entry_type,
          financial_entry.external_id
        ].join(" - ")
      end

      def category_code
        settings.categoria_para(financial_entry.entry_type)
      end
    end
  end
end
