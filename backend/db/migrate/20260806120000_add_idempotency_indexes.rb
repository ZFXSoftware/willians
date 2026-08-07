class AddIdempotencyIndexes < ActiveRecord::Migration[8.1]
  def change
    # PayoutEngine é idempotente pela referência externa do repasse; sem isso a
    # garantia dependia só do find_by antes do create.
    unless index_exists?(:payout_batches, [:tenant_id, :external_id], name: "idx_payout_batches_unique")
      add_index :payout_batches,
                [:tenant_id, :external_id],
                unique: true,
                name: "idx_payout_batches_unique"
    end

    # Um lançamento é alocado uma única vez por recebível e por tipo de alocação
    # (uma 'receivable' na projeção, uma 'payout' na liquidação).
    unless index_exists?(
      :financial_entry_allocations,
      [:receivable_unit_id, :financial_entry_id, :allocation_type],
      name: "idx_allocations_unique"
    )
      add_index :financial_entry_allocations,
                [:receivable_unit_id, :financial_entry_id, :allocation_type],
                unique: true,
                name: "idx_allocations_unique"
    end

    # O scheduler roda a cada poucos minutos: sem isso cada execução reabriria a
    # mesma divergência e o backlog cresceria indefinidamente.
    unless index_exists?(
      :divergence_reports,
      [:financial_entry_id, :divergence_type, :status],
      name: "idx_divergence_reports_unique"
    )
      add_index :divergence_reports,
                [:financial_entry_id, :divergence_type, :status],
                unique: true,
                name: "idx_divergence_reports_unique"
    end
  end
end
