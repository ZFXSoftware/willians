class CreateFinancialEntryAllocations < ActiveRecord::Migration[8.0]
  def change
    create_table :financial_entry_allocations do |t|
      t.references :tenant,
                   null: false,
                   foreign_key: true

      t.references :financial_entry,
                   null: false,
                   foreign_key: true

      t.references :invoice,
                   foreign_key: true

      t.references :order,
                   foreign_key: true

      t.string :allocation_type,
               null: false

      t.decimal :allocated_amount,
                precision: 15,
                scale: 2,
                null: false

      t.jsonb :metadata,
              null: false,
              default: {}

      t.timestamps
    end

    add_index :financial_entry_allocations,
              :allocation_type

    add_index :financial_entry_allocations,
              :allocated_amount
  end
end