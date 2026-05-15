class CreateOmieFinancialMappings < ActiveRecord::Migration[8.0]
  def change
    create_table :omie_financial_mappings do |t|
      t.references :tenant,
                   null: false,
                   foreign_key: true

      t.references :financial_entry,
                   null: false,
                   foreign_key: true

      t.string :omie_financial_id
      t.string :omie_category_id
      t.string :omie_account_id

      t.boolean :synced,
                null: false,
                default: false

      t.datetime :synced_at

      t.jsonb :metadata,
              null: false,
              default: {}

      t.timestamps
    end

    add_index :omie_financial_mappings,
              :omie_financial_id

    add_index :omie_financial_mappings,
              :synced
  end
end