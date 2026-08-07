module Conciliacao
  # Valor de retorno da comparação entre o que o marketplace repassou e o que o
  # OMIE reconhece de título. Não toca em persistência: só descreve a qualidade
  # do match.
  class ResultadoConciliacao
    TOLERANCIA = BigDecimal("0.01")

    STATUSES = %i[ok divergente nao_encontrado].freeze

    attr_reader :status,
                :mensagem,
                :diferenca,
                :valor_interno,
                :valor_omie

    def initialize(
      status:,
      mensagem: nil,
      diferenca: BigDecimal("0"),
      valor_interno: nil,
      valor_omie: nil
    )
      @status = status

      @mensagem = mensagem

      @diferenca = diferenca

      @valor_interno = valor_interno

      @valor_omie = valor_omie
    end

    def ok?
      status == :ok
    end

    def divergente?
      status == :divergente
    end

    def nao_encontrado?
      status == :nao_encontrado
    end

    def exato?
      ok? && diferenca.zero?
    end

    def match_type
      return if nao_encontrado?

      exato? ? :exact : :approximate
    end

    # 100 para match exato, decaindo proporcionalmente à diferença relativa.
    def confidence_score
      return BigDecimal("0") if nao_encontrado?

      return BigDecimal("100") if exato?

      base = valor_interno.to_d.abs

      return BigDecimal("0") if base.zero?

      score = (1 - (diferenca.abs / base)) * 100

      score.clamp(BigDecimal("0"), BigDecimal("100")).round(2)
    end
  end
end
