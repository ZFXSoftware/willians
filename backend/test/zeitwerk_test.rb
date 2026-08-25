require "test_helper"
require "English"

# O autoload precisa fechar num processo FRIO.
#
# Este teste existe porque um marcador declarado no arquivo errado
# (Marketplace::Providers::AindaNaoPronto, dentro de base_provider.rb) passou
# pela suíte inteira e derrubou o backend no boot da produção. Em teste ele
# carregava por sorte de ordem: algum outro teste já tinha tocado o
# base_provider antes, então a constante existia quando alguém pediu por ela.
#
# Por isso aqui é um processo separado, e não `Rails.application.eager_load!`
# dentro da suíte: chamar o eager load depois que meio app já está carregado
# não prova nada — foi exatamente o que aconteceu.
class ZeitwerkTest < ActiveSupport::TestCase
  test "o app inteiro carrega do zero" do
    saida = nil

    Dir.chdir(Rails.root) do
      saida = `bin/rails zeitwerk:check 2>&1`
    end

    assert_predicate $CHILD_STATUS, :success?, <<~AVISO
      O eager load falhou. Em produção isso é o backend não subir.

      A causa quase sempre é uma constante em arquivo que não tem o nome dela:
      o Zeitwerk espera Um::Dois::Tres em um/dois/tres.rb, e uma constante
      declarada de carona dentro de outro arquivo só carrega se alguém tiver
      carregado esse outro arquivo antes — o que em teste acontece por acaso.

      #{saida}
    AVISO
  end
end
