module Omie
  module Readers
    # Títulos A PAGAR em aberto, indexados pelo número da nota fiscal.
    #
    # Espelho do OpenTitles do lado do contas a pagar. Serve ao briefing 2.7:
    # quando o pagamento de uma NF é feito direto na plataforma, é aqui que
    # está o título que precisa ser baixado no OMIE.
    class OpenPayables
      ENDPOINT = "financas/contapagar/".freeze

      CALL = "ListarContasPagar".freeze

      PAGE_SIZE = 500

      MAX_PAGES = 200

      Titulo = Struct.new(
        :codigo_lancamento_omie,
        :numero_nf,
        :valor,
        :vencimento,
        :status,
        :fornecedor_id,
        :conta_corrente_id,
        keyword_init: true
      )

      def initialize(client:)
        @client = client
      end

      # => { "251372" => [Titulo, ...] }
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

          registros = resposta["conta_pagar_cadastro"] || []

          registros.each { |registro| yield(registro) }

          total = (resposta["total_de_paginas"] || 1).to_i

          break if registros.empty? || pagina >= total

          if pagina >= MAX_PAGES
            Rails.logger.warn "[Omie] varredura de contas a pagar truncada em #{MAX_PAGES} páginas"

            break
          end

          pagina += 1
        end
      end

      def buscar_pagina(pagina, start_date, end_date)
        params = {
          pagina: pagina,
          registros_por_pagina: PAGE_SIZE,
          filtrar_apenas_titulos_em_aberto: "S"
        }

        params[:filtrar_por_emissao_de] = formatar(start_date) if start_date

        params[:filtrar_por_emissao_ate] = formatar(end_date) if end_date

        client.request(ENDPOINT, CALL, params)
      end

      def formatar(data) = data&.to_date&.strftime("%d/%m/%Y")

      def numero_nf(registro)
        bruto = registro["numero_documento_fiscal"].presence ||
                registro["numero_documento"].presence

        OpenTitles.normalizar_numero(bruto)
      end

      def construir(registro, numero)
        Titulo.new(
          codigo_lancamento_omie: registro["codigo_lancamento_omie"],
          numero_nf: numero,
          valor: registro["valor_documento"].to_d,
          vencimento: registro["data_vencimento"],
          status: registro["status_titulo"],
          fornecedor_id: registro["codigo_cliente_fornecedor"],
          conta_corrente_id: registro["id_conta_corrente"]
        )
      end
    end
  end
end
