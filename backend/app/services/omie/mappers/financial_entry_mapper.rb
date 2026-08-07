module Omie
  module Mappers
    # Monta o payload de IncluirContaReceber.
    #
    # Campos obrigatórios conforme a doc do OMIE: codigo_lancamento_integracao,
    # codigo_cliente_fornecedor, data_vencimento, valor_documento,
    # codigo_categoria, data_previsao e id_conta_corrente.
    class FinancialEntryMapper
      # Namespace dos títulos criados por nós.
      #
      # O Omie do cliente já tem títulos do TrackCash, que usa o prefixo `R_` em
      # codigo_lancamento_integracao. Durante a substituição os dois sistemas
      # convivem, então nossos lançamentos precisam ser distinguíveis — e nunca
      # sobrescrever a referência do outro.
      INTEGRATION_PREFIX = "WLL".freeze

      def initialize(financial_entry:)
        @financial_entry = financial_entry
      end

      def call
        @call ||= {
          # Identifica o título como nosso e permite reencontrá-lo sem depender
          # de valor ou data. NÃO é a chave de conciliação — essa é o número da
          # nota fiscal, que é o que existe nos títulos de todas as origens.
          codigo_lancamento_integracao:
            "#{INTEGRATION_PREFIX}-#{financial_entry.id}",

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
