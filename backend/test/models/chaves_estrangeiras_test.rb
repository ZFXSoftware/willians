require "test_helper"

# Toda chave estrangeira precisa da associação do lado de lá.
#
# Sem ela o Rails não sabe o que fazer com os filhos ao apagar o pai, e o
# `destroy` morre com violação de chave estrangeira — em produção, na cara do
# usuário. Foi assim que "Remover" não removia a conta de marketplace:
# `oauth_states` apontava para `platform_accounts` e ninguém tinha declarado o
# `has_many`.
#
# Este teste varre o schema inteiro em vez de listar os casos conhecidos,
# porque o próximo esquecimento vai ser em outra tabela.
class ChavesEstrangeirasTest < ActiveSupport::TestCase
  test "toda FK tem associação inversa declarada no modelo pai" do
    Rails.application.eager_load!

    conexao = ActiveRecord::Base.connection

    faltando = conexao.tables.flat_map do |tabela|
      conexao.foreign_keys(tabela).filter_map do |fk|
        pai = modelo_de(fk.to_table)

        next if pai.nil?

        next if coberta?(pai, tabela, fk.column)

        "#{fk.to_table} <- #{tabela}.#{fk.column}"
      end
    end

    assert_empty faltando.sort, <<~AVISO
      Chave(s) estrangeira(s) sem has_many/has_one no modelo pai.

      Apagar o pai vai estourar ActiveRecord::InvalidForeignKey. Declare a
      associação escolhendo o destino dos filhos DE PROPÓSITO:

        dependent: :destroy   o filho não faz sentido sem o pai
        dependent: :nullify   o filho sobrevive, perde só o vínculo

      Nunca escolha :destroy por comodidade em cima de dado financeiro.
    AVISO
  end

  private

  def modelo_de(tabela)
    ApplicationRecord.descendants.find { |m| m.table_name == tabela && !m.abstract_class? }
  end

  def coberta?(pai, tabela_filha, coluna)
    pai.reflect_on_all_associations.any? do |associacao|
      next false unless %i[has_many has_one].include?(associacao.macro)

      # Associação com class_name quebrado ou polimórfica levanta ao resolver
      # a classe; isso não é o que este teste mede.
      associacao.klass.table_name == tabela_filha &&
        associacao.foreign_key.to_s == coluna.to_s
    rescue StandardError
      false
    end
  end
end
