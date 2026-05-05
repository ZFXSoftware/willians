class CreateNotaFiscals < ActiveRecord::Migration[8.1]
  def change
    create_table :nota_fiscals do |t|
      t.string :numero
      t.decimal :valor

      t.timestamps
    end
  end
end
