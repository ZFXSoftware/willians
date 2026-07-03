class HardenFinancialEntryAllocations < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:financial_entry_allocations, :receivable_unit_id)
      add_reference :financial_entry_allocations,
                    :receivable_unit,
                    foreign_key: true
    end

    unless column_exists?(:financial_entry_allocations, :payout_batch_id)
      add_reference :financial_entry_allocations,
                    :payout_batch,
                    foreign_key: true
    end

    unless column_exists?(:financial_entry_allocations, :allocation_type)
      add_column :financial_entry_allocations,
                 :allocation_type,
                 :string
    end

    unless column_exists?(:financial_entry_allocations, :amount)
      add_column :financial_entry_allocations,
                 :amount,
                 :decimal,
                 precision: 15,
                 scale: 2,
                 default: 0
    end

    unless column_exists?(:financial_entry_allocations, :metadata)
      add_column :financial_entry_allocations,
                 :metadata,
                 :jsonb,
                 default: {}
    end
  end
end