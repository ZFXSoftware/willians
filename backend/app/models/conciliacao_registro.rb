class ConciliacaoRegistro < ApplicationRecord
  belongs_to :tenant,
             optional: true

  belongs_to :conciliation_run,
             optional: true

  belongs_to :financial_entry,
             optional: true

  belongs_to :receivable_unit,
             optional: true

  belongs_to :payout_batch,
             optional: true

  enum :status, {
    pending: "pending",
    matched: "matched",
    divergent: "divergent",
    manual_review: "manual_review",
    resolved: "resolved"
  }

  enum :match_type, {
    exact: "exact",
    approximate: "approximate",
    batch: "batch",
    manual: "manual"
  }

  validates :status,
            presence: true
end