class CreateConciliationRuns < ActiveRecord::Migration[8.0]
  def change
    create_table :conciliation_runs do |t|
      t.references :tenant,
                   null: false,
                   foreign_key: true

      t.string :platform,
               null: false

      t.string :status,
               null: false,
               default: "pending"

      t.datetime :started_at
      t.datetime :finished_at

      t.integer :total_entries,
                default: 0,
                null: false

      t.integer :reconciled_entries,
                default: 0,
                null: false

      t.integer :divergent_entries,
                default: 0,
                null: false

      t.jsonb :metadata,
              null: false,
              default: {}

      t.timestamps
    end

    add_index :conciliation_runs, :platform
    add_index :conciliation_runs, :status
  end
end