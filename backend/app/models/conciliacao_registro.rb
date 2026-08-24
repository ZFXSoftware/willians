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

  # O lado inverso da FK financial_entries.conciliacao_registro_id. Nullify e
  # não destroy: desfazer uma conciliação não pode apagar o LANÇAMENTO, que é
  # o fato financeiro — some o vínculo, fica o dinheiro.
  has_many :financial_entries,
           dependent: :nullify,
           inverse_of: :conciliacao_registro

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
