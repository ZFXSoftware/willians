class CreateFinancialEntries < ActiveRecord::Migration[8.0]
  def change
    create_table :financial_entries do |t|
      t.references :tenant, null: false, foreign_key: true

      t.references :platform_account,
                   foreign_key: true

      t.references :order,
                   foreign_key: true

      t.references :invoice,
                   foreign_key: true

      t.references :conciliacao_registro,
                   foreign_key: true

      t.string :external_id,
               null: false

      t.string :external_reference

      t.string :entry_type,
               null: false

      t.string :status,
               null: false,
               default: "pending"

      t.decimal :amount,
                precision: 15,
                scale: 2,
                null: false

      t.decimal :fee_amount,
                precision: 15,
                scale: 2,
                default: 0,
                null: false

      t.decimal :net_amount,
                precision: 15,
                scale: 2,
                default: 0,
                null: false

      t.datetime :occurred_at,
                 null: false

      t.datetime :expected_settlement_at

      t.datetime :settled_at

      t.decimal :virtual_balance_after,
                precision: 15,
                scale: 2

      t.jsonb :metadata,
              null: false,
              default: {}

      t.boolean :reconciled,
                null: false,
                default: false

      t.datetime :reconciled_at

      t.boolean :has_divergence,
                null: false,
                default: false

      t.text :divergence_reason

      t.timestamps
    end

    add_index :financial_entries,
              [:tenant_id, :external_id, :entry_type],
              unique: true,
              name: "idx_financial_entries_unique"

    add_index :financial_entries, :entry_type
    add_index :financial_entries, :status
    add_index :financial_entries, :occurred_at
    add_index :financial_entries, :expected_settlement_at
    add_index :financial_entries, :reconciled
    add_index :financial_entries, :has_divergence
  end
end