module Omie
  # Cliente de SIMULAÇÃO usado quando OMIE_APP_KEY/OMIE_APP_SECRET não estão
  # configurados. Deriva os "títulos" dos recebíveis já existentes no banco para
  # que o fluxo de conciliação possa ser exercitado ponta a ponta sem credencial.
  #
  # Para tornar o cenário demonstrável, uma fração determinística dos títulos sai
  # com valor divergente — assim tanto o caminho de match quanto o de divergência
  # são percorridos.
  class FakeOmieClient
    DIVERGENCE_EVERY = 5

    DIVERGENCE_RATE = BigDecimal("0.975")

    def self.configured?
      true
    end

    # titulos: permite injetar títulos manualmente (testes/demos dirigidas).
    def initialize(titulos: nil)
      @titulos = titulos
    end

    def request(endpoint, call, params = {})
      case call.to_s
      when "ListarContasReceber"
        listar_contas_receber(params)

      when "IncluirContaReceber"
        {
          "codigo_lancamento_omie" => fake_omie_id(params),
          "codigo_lancamento_integracao" => params[:codigo_lancamento_integracao],
          "descricao_status" => "Simulado"
        }

      when "LancarRecebimento"
        {
          "codigo_lancamento" => params[:codigo_lancamento],
          "codigo_baixa" => 800_000 + params[:codigo_lancamento].to_i % 100_000,
          "descricao_status" => "Recebimento simulado"
        }

      else
        { "descricao_status" => "Chamada simulada: #{call}" }
      end
    end

    private

    def listar_contas_receber(params)
      pagina = (params[:pagina] || 1).to_i

      por_pagina = (params[:registros_por_pagina] || 500).to_i

      registros = titulos_para(params)

      total_paginas = [(registros.size.to_f / por_pagina).ceil, 1].max

      pagina_registros =
        registros.slice(
          (pagina - 1) * por_pagina,
          por_pagina
        ) || []

      {
        "pagina" => pagina,
        "total_de_paginas" => total_paginas,
        "registros" => pagina_registros.size,
        "total_de_registros" => registros.size,
        "conta_receber_cadastro" => pagina_registros
      }
    end

    def titulos_para(params)
      return @titulos if @titulos

      scope = ReceivableUnit.order(:id)

      de = parse_date(params[:filtrar_por_emissao_de])

      ate = parse_date(params[:filtrar_por_emissao_ate])

      scope = scope.where(expected_on: de..) if de

      scope = scope.where(expected_on: ..ate) if ate

      scope.map { |receivable| titulo_from(receivable) }
    end

    def titulo_from(receivable)
      valor = receivable.gross_amount.to_d

      valor *= DIVERGENCE_RATE if divergent?(receivable)

      {
        "codigo_lancamento_omie" => 900_000 + receivable.id,
        "codigo_lancamento_integracao" => receivable.external_id,
        "numero_documento" => receivable.external_id,
        "valor_documento" => valor.round(2).to_f,
        "data_vencimento" => receivable.expected_on&.strftime("%d/%m/%Y")
      }
    end

    def divergent?(receivable)
      (receivable.id % DIVERGENCE_EVERY).zero?
    end

    def parse_date(value)
      return if value.blank?

      Date.strptime(value.to_s, "%d/%m/%Y")
    rescue Date::Error
      nil
    end

    def fake_omie_id(params)
      900_000 + params[:codigo_lancamento_integracao].to_s.hash.abs % 100_000
    end
  end
end
