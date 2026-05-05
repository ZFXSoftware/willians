class CreateConciliacaoRegistros < ActiveRecord::Migration[8.1]
  def change
    create_table :conciliacao_registros do |t|
      t.string :status
      t.text :descricao

      t.timestamps
    end
  end
end
