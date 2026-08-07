class PayoutBatch < ApplicationRecord
  belongs_to :tenant

  belongs_to :platform_account

  belongs_to :financial_entry,
             optional: true

  has_many :financial_entry_allocations,
           dependent: :destroy

  has_many :financial_entries,
           through: :financial_entry_allocations

  has_many :conciliacao_registros,
           dependent: :nullify

  enum :status, {
    pending: "pending",
    processing: "processing",
    paid: "paid",
    failed: "failed",
    cancelled: "cancelled"
  }

  validates :net_amount,
            presence: true
end
