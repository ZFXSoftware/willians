class AddCamposToConciliacaoRegistros < ActiveRecord::Migration[8.1]
  def change
    add_column :conciliacao_registros, :referencia, :string
    add_column :conciliacao_registros, :valor, :decimal, precision: 15, scale: 2
    add_column :conciliacao_registros, :diferenca, :decimal, precision: 15, scale: 2
    add_column :conciliacao_registros, :observacao, :text
  end
end