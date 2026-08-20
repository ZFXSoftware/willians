# Dublês compartilhados. Registram o que foi chamado, para que os testes possam
# afirmar sobre a requisição e não só sobre o retorno.

# Cliente do OMIE que grava as chamadas em vez de sair para a rede.
class OmieEspiao
  attr_reader :chamadas

  def initialize(respostas: {})
    @chamadas = []
    @respostas = respostas
  end

  def request(endpoint, call, params = {})
    @chamadas << { endpoint: endpoint, call: call, params: params }

    @respostas.fetch(call) do
      { "codigo_lancamento_omie" => 4_200_000 + @chamadas.size,
        "codigo_baixa" => 700_000 + @chamadas.size,
        "codigo_status" => "0" }
    end
  end

  def chamadas_de(call) = chamadas.select { |c| c[:call] == call }

  def params_de(call) = chamadas_de(call).map { |c| c[:params] }
end

# Índice de títulos do OMIE no formato que os serviços consomem.
module TitulosFalsos
  def self.indice(*titulos)
    titulos.each_with_object(Hash.new { |h, k| h[k] = [] }) do |t, acc|
      acc[Omie::Readers::OpenTitles.normalizar_numero(t.numero_nf)] << t
    end
  end

  def self.titulo(codigo:, numero:, valor:, previsao: nil)
    Omie::Readers::OpenTitles::Titulo.new(
      codigo_lancamento_omie: codigo,
      numero_nf: Omie::Readers::OpenTitles.normalizar_numero(numero),
      valor: BigDecimal(valor.to_s),
      previsao: previsao
    )
  end
end
