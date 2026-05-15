class CreateDivergenceReports < ActiveRecord::Migration[8.0]
  def change
    create_table :divergence_reports do |t|
      t.references :tenant,
                   null: false,
                   foreign_key: true

      t.references :financial_entry,
                   null: false,
                   foreign_key: true

      t.string :divergence_type,
               null: false

      t.string :status,
               null: false,
               default: "open"

      t.decimal :expected_amount,
                precision: 15,
                scale: 2

      t.decimal :received_amount,
                precision: 15,
                scale: 2

      t.decimal :difference_amount,
                precision: 15,
                scale: 2

      t.text :resolution_notes

      t.datetime :resolved_at

      t.jsonb :metadata,
              null: false,
              default: {}

      t.timestamps
    end

    add_index :divergence_reports,
              :divergence_type

    add_index :divergence_reports,
              :status
  end
end