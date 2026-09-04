require "test_helper"

# A fila da SEFAZ é incremental e o antiabuso conta por CNPJ. O que se testa
# aqui é o que evita levar bloqueio: nunca andar para trás, e respeitar a
# espera quando ela vier.
class LeituraSefazTest < ActiveSupport::TestCase
  def setup
    @tenant = criar_tenant
    @leitura = LeituraSefaz.create!(tenant: @tenant)
  end

  def resposta(codigo:, ultimo_nsu:, max_nsu: 0, motivo: "ok")
    Fiscal::Sefaz::DistribuicaoDfe::Resposta.new(
      codigo: codigo, motivo: motivo, ultimo_nsu: ultimo_nsu.to_s,
      max_nsu: max_nsu.to_s, documentos: [], bruto: ""
    )
  end

  test "avança o marcador e limpa o bloqueio" do
    @leitura.avancar!(resposta(codigo: "138", ultimo_nsu: 100, max_nsu: 500))

    assert_equal 100, @leitura.ultimo_nsu
    assert_equal 500, @leitura.max_nsu
    assert_not @leitura.bloqueada?
  end

  # Andar para trás na fila é exatamente o que dispara o consumo indevido.
  test "nunca retrocede o marcador" do
    @leitura.avancar!(resposta(codigo: "138", ultimo_nsu: 100))
    @leitura.avancar!(resposta(codigo: "138", ultimo_nsu: 40))

    assert_equal 100, @leitura.ultimo_nsu
  end

  # O NSU que vem NA REJEIÇÃO é a informação mais confiável sobre onde a fila
  # está — foi assim que descobrimos que este CNPJ já estava em 75377.
  test "a rejeição por consumo indevido aproveita o NSU e bloqueia" do
    @leitura.bloquear!(resposta(codigo: "656", ultimo_nsu: 75_377, motivo: "Consumo Indevido"))

    assert_equal 75_377, @leitura.ultimo_nsu
    assert_predicate @leitura, :bloqueada?
    assert_operator @leitura.minutos_de_espera, :>, 60
  end

  test "o bloqueio expira sozinho" do
    @leitura.bloquear!(resposta(codigo: "656", ultimo_nsu: 10))

    @leitura.update!(bloqueado_ate: 1.minute.ago)

    assert_not @leitura.bloqueada?
    assert_equal 0, @leitura.minutos_de_espera
  end

  test "sabe quanto falta para o fim da fila" do
    @leitura.avancar!(resposta(codigo: "138", ultimo_nsu: 100, max_nsu: 250))

    assert_equal 150, @leitura.faltam
  end

  test "sem max_nsu, não inventa quanto falta" do
    assert_nil @leitura.faltam
  end
end
