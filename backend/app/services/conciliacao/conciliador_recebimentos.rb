module Conciliacao
  # Primitiva de match: compara dois valores e classifica o resultado.
  # `valor_omie` nulo significa que não existe título correspondente no ERP —
  # caso diferente de existir com valor zero.
  class ConciliadorRecebimentos
    def self.conciliar(
      valor_interno:,
      valor_omie:,
      tolerancia: ResultadoConciliacao::TOLERANCIA
    )
      interno = valor_interno.to_d

      if valor_omie.nil?
        return ResultadoConciliacao.new(
          status: :nao_encontrado,

          mensagem: "Sem título correspondente no OMIE",

          diferenca: interno,

          valor_interno: interno,

          valor_omie: nil
        )
      end

      omie = valor_omie.to_d

      diferenca = interno - omie

      if diferenca.abs <= tolerancia
        ResultadoConciliacao.new(
          status: :ok,

          diferenca: diferenca,

          valor_interno: interno,

          valor_omie: omie
        )
      else
        ResultadoConciliacao.new(
          status: :divergente,

          mensagem: "Diferença de #{diferenca.round(2).to_s('F')} entre repasse e título",

          diferenca: diferenca,

          valor_interno: interno,

          valor_omie: omie
        )
      end
    end
  end
end
