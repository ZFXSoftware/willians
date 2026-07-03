class HardenFinancialEntriesLedger < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:financial_entries, :direction)
      add_column :financial_entries,
                 :direction,
                 :string
    end

    unless column_exists?(:financial_entries, :source)
      add_column :financial_entries,
                 :source,
                 :string
    end

    unless column_exists?(:financial_entries, :occurred_at)
      add_column :financial_entries,
                 :occurred_at,
                 :datetime
    end

    unless column_exists?(:financial_entries, :available_on)
      add_column :financial_entries,
                 :available_on,
                 :date
    end

    unless column_exists?(:financial_entries, :raw_payload)
      add_column :financial_entries,
                 :raw_payload,
                 :jsonb,
                 default: {}
    end

    unless column_exists?(:financial_entries, :immutable)
      add_column :financial_entries,
                 :immutable,
                 :boolean,
                 default: false,
                 null: false
    end

    unless column_exists?(:financial_entries, :reversal_of_id)
      add_reference :financial_entries,
                    :reversal_of,
                    foreign_key: {
                      to_table: :financial_entries
                    }
    end

    unless index_exists?(
      :financial_entries,
      [:tenant_id, :source, :external_id],
      name: "idx_financial_entries_idempotency"
    )
      add_index :financial_entries,
                [:tenant_id, :source, :external_id],
                unique: true,
                name: "idx_financial_entries_idempotency"
    end

    add_index :financial_entries,
              :occurred_at unless index_exists?(:financial_entries, :occurred_at)

    add_index :financial_entries,
              :available_on unless index_exists?(:financial_entries, :available_on)

    add_index :financial_entries,
              :direction unless index_exists?(:financial_entries, :direction)

    add_index :financial_entries,
              :source unless index_exists?(:financial_entries, :source)
  end
end