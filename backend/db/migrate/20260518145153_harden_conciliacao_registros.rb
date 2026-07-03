class HardenConciliacaoRegistros < ActiveRecord::Migration[8.0]
  def change
    change_table :conciliacao_registros do |t|
      t.references :tenant,
                   foreign_key: true

      t.references :conciliation_run,
                   foreign_key: true

      t.references :financial_entry,
                   foreign_key: true

      t.references :receivable_unit,
                   foreign_key: true

      t.references :payout_batch,
                   foreign_key: true

      t.string :match_type

      t.decimal :confidence_score,
                precision: 5,
                scale: 2,
                default: 0

      t.jsonb :conciliation_metadata,
              default: {}

      t.datetime :conciliated_at
    end

    add_index :conciliacao_registros,
              :match_type

    add_index :conciliacao_registros,
              :confidence_score
  end
end