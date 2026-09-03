module Omie
  module Readers
    # Carrega, em uma única varredura paginada, o total de título a receber que o
    # OMIE reconhece por referência de integração.
    #
    # Existe para evitar uma chamada HTTP por repasse durante a conciliação: o
    # índice é montado uma vez e consultado em memória pelo engine.
    class ReceivableTotals
      ENDPOINT = "financas/contareceber/"

      CALL = "ListarContasReceber"

      PAGE_SIZE = 500

      MAX_PAGES = 200

      def initialize(client:)
        @client = client
      end

      # Zero à esquerda não pode decidir se um título é encontrado.
      #
      # As notas do cliente saem em duas séries — "042054" e "852276" — e o
      # OMIE guarda o número como o sistema que criou o título mandou. Comparar
      # as strings cruas faz "042054" e "42054" serem títulos diferentes, e o
      # repasse inteiro sai como "sem título correspondente" por causa de um
      # zero. O `tiny:check` já normalizava dos dois lados; o motor não.
      def self.normalizar(numero)
        limpo = numero.to_s.strip

        return if limpo.blank?

        limpo.sub(/\A0+/, "").presence || limpo
      end

      # => { "referencia" => BigDecimal }
      def call(start_date:, end_date:)
        totals = Hash.new(BigDecimal("0"))

        each_record(start_date, end_date) do |record|
          key = reference_for(record)

          next if key.blank?

          totals[key] += record["valor_documento"].to_d
        end

        totals
      end

      private

      attr_reader :client

      def each_record(start_date, end_date)
        pagina = 1

        loop do
          response = fetch_page(pagina, start_date, end_date)

          records = response["conta_receber_cadastro"] || []

          records.each { |record| yield(record) }

          total_paginas = (response["total_de_paginas"] || 1).to_i

          break if pagina >= total_paginas || pagina >= MAX_PAGES

          break if records.empty?

          pagina += 1
        end
      end

      # Filtro por EMISSÃO, não por `filtrar_por_data_de/ate` — esses filtram
      # data de inclusão/alteração do registro no OMIE, que não tem relação com
      # a data do título.
      def fetch_page(pagina, start_date, end_date)
        client.request(
          ENDPOINT,

          CALL,

          pagina: pagina,

          registros_por_pagina: PAGE_SIZE,

          filtrar_por_emissao_de: format_date(start_date),

          filtrar_por_emissao_ate: format_date(end_date)
        )
      end

      # A chave de conciliação é o NÚMERO DA NOTA FISCAL.
      #
      # Medido no Omie do cliente: `codigo_tipo_documento` é NFE em 100% dos
      # títulos, mas `numero_documento_fiscal` vem preenchido em apenas 1% — nos
      # títulos importados o número da NF fica em `numero_documento`.
      #
      # `codigo_lancamento_integracao` NÃO serve: pertence a quem criou o
      # título (hoje o TrackCash, com prefixo `R_`) e não é um dado de negócio.
      def reference_for(record)
        self.class.normalizar(
          record["numero_documento_fiscal"].presence || record["numero_documento"]
        )
      end

      def format_date(date)
        date&.to_date&.strftime("%d/%m/%Y")
      end
    end
  end
end
