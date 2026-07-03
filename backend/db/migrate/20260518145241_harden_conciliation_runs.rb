class HardenConciliationRuns < ActiveRecord::Migration[8.0]
  def change
    unless column_exists?(:conciliation_runs, :tenant_id)
      add_reference :conciliation_runs,
                    :tenant,
                    foreign_key: true
    end

    unless column_exists?(:conciliation_runs, :platform_account_id)
      add_reference :conciliation_runs,
                    :platform_account,
                    foreign_key: true
    end

    unless column_exists?(:conciliation_runs, :source)
      add_column :conciliation_runs,
                 :source,
                 :string
    end

    unless column_exists?(:conciliation_runs, :started_at)
      add_column :conciliation_runs,
                 :started_at,
                 :datetime
    end

    unless column_exists?(:conciliation_runs, :finished_at)
      add_column :conciliation_runs,
                 :finished_at,
                 :datetime
    end

    unless column_exists?(:conciliation_runs, :entries_processed)
      add_column :conciliation_runs,
                 :entries_processed,
                 :integer,
                 default: 0
    end

    unless column_exists?(:conciliation_runs, :matches_found)
      add_column :conciliation_runs,
                 :matches_found,
                 :integer,
                 default: 0
    end

    unless column_exists?(:conciliation_runs, :divergences_found)
      add_column :conciliation_runs,
                 :divergences_found,
                 :integer,
                 default: 0
    end

    unless column_exists?(:conciliation_runs, :metadata)
      add_column :conciliation_runs,
                 :metadata,
                 :jsonb,
                 default: {}
    end
  end
end