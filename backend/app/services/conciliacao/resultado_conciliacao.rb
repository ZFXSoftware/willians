module Conciliacao
  class ResultadoConciliacao
    attr_reader :status, :mensagem, :diferenca

    def initialize(status:, mensagem: nil, diferenca: 0)
      @status = status # :ok, :divergente, :nao_encontrado
      @mensagem = mensagem
      @diferenca = diferenca
    end

    def ok?
      status == :ok
    end

    def divergente?
      status == :divergente
    end
  end
end