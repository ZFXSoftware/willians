class ReceivableUnit < ApplicationRecord
  belongs_to :tenant

  belongs_to :platform_account,
             optional: true

  belongs_to :order,
             optional: true

  belongs_to :invoice,
             optional: true

  has_many :financial_entry_allocations,
           dependent: :destroy

  has_many :financial_entries,
           through: :financial_entry_allocations

  # Mesma razão do ConciliacaoRegistro: o registro de conciliação sobrevive ao
  # título, sem o vínculo. Sem esta linha o destroy da unidade batia na FK.
  has_many :conciliacao_registros,
           dependent: :nullify,
           inverse_of: :receivable_unit

  enum :status, {
    pending: "pending",
    scheduled: "scheduled",
    partially_paid: "partially_paid",
    available: "available",
    paid: "paid",
    blocked: "blocked",
    disputed: "disputed",
    cancelled: "cancelled"
  }

  validates :gross_amount,
            presence: true

  validates :net_amount,
            presence: true

  scope :scheduled_for_payment, ->(date) {
    where(
      status: :scheduled,
      expected_on: ..date
    )
  }
end