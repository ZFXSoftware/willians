module Conciliacao
  class ConciliadorRecebimentos
    def self.conciliar(omie:, interno:)
      return ResultadoConciliacao.new(
        status: :nao_encontrado,
        mensagem: "Não encontrado no sistema interno"
      ) unless interno

      valor_omie = omie["valor_documento"].to_f
      valor_interno = interno.valor.to_f

      diferenca = valor_omie - valor_interno

      if diferenca.abs < 0.01
        ResultadoConciliacao.new(status: :ok)
      else
        ResultadoConciliacao.new(
          status: :divergente,
          mensagem: "Diferença detectada",
          diferenca: diferenca
        )
      end
    end
  end
end