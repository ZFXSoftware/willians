module Omie
  module Readers
    # Títulos EM ABERTO indexados pelo número da nota fiscal.
    #
    # Diferente do ReceivableTotals, que só soma valores para comparar, aqui
    # interessa o `codigo_lancamento_omie` — é ele que a baixa
    # (LancarRecebimento) exige.
    #
    # O índice é por número de NF porque é o único identificador presente em
    # todos os títulos da base do cliente: `codigo_tipo_documento` é NFE em
    # 100% deles, mas `numero_documento_fiscal` vem preenchido em só 1% — nos
    # títulos importados o número fica em `numero_documento`.
    class OpenTitles
      ENDPOINT = "financas/contareceber/".freeze

      CALL = "ListarContasReceber".freeze

      PAGE_SIZE = 500

      MAX_PAGES = 200

      Titulo = Struct.new(
        :codigo_lancamento_omie,
        :numero_nf,
        :valor,
        :vencimento,
        :status,
        :cliente_id,
        :conta_corrente_id,
        keyword_init: true
      )

      def initialize(client:)
        @client = client
      end

      # => { "251372" => [Titulo, ...] }
      #
      # Vários títulos podem compartilhar a mesma NF (parcelas), por isso o
      # valor do índice é uma lista.
      def por_nota_fiscal(start_date: nil, end_date: nil)
        indice = Hash.new { |h, k| h[k] = [] }

        each_titulo(start_date, end_date) do |registro|
          numero = numero_nf(registro)

          next if numero.blank?

          indice[numero] << construir(registro, numero)
        end

        indice
      end

      private

      attr_reader :client

      def each_titulo(start_date, end_date)
        pagina = 1

        loop do
          resposta = buscar_pagina(pagina, start_date, end_date)

          registros = resposta["conta_receber_cadastro"] || []

          registros.each { |registro| yield(registro) }

          total = (resposta["total_de_paginas"] || 1).to_i

          break if registros.empty? || pagina >= total

          if pagina >= MAX_PAGES
            Rails.logger.warn "[Omie] varredura de títulos truncada em #{MAX_PAGES} páginas"

            break
          end

          pagina += 1
        end
      end

      def buscar_pagina(pagina, start_date, end_date)
        params = {
          pagina: pagina,
          registros_por_pagina: PAGE_SIZE,
          # Só interessa o que ainda não foi baixado.
          filtrar_apenas_titulos_em_aberto: "S"
        }

        params[:filtrar_por_emissao_de] = formatar(start_date) if start_date

        params[:filtrar_por_emissao_ate] = formatar(end_date) if end_date

        client.request(ENDPOINT, CALL, params)
      end

      def formatar(data)
        data&.to_date&.strftime("%d/%m/%Y")
      end

      # Zeros à esquerda variam entre sistemas ("000251372" x "251372").
      def numero_nf(registro)
        bruto = registro["numero_documento_fiscal"].presence ||
                registro["numero_documento"].presence

        self.class.normalizar_numero(bruto)
      end

      def self.normalizar_numero(valor)
        valor.to_s.strip.sub(/\A0+/, "").presence
      end

      def construir(registro, numero)
        Titulo.new(
          codigo_lancamento_omie: registro["codigo_lancamento_omie"],
          numero_nf: numero,
          valor: registro["valor_documento"].to_d,
          vencimento: registro["data_vencimento"],
          status: registro["status_titulo"],
          cliente_id: registro["codigo_cliente_fornecedor"],
          conta_corrente_id: registro["id_conta_corrente"]
        )
      end
    end
  end
end
