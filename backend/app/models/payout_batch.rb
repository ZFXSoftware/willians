class PayoutBatch < ApplicationRecord
  belongs_to :tenant

  belongs_to :platform_account,
             optional: true

  has_many :financial_entry_allocations,
           dependent: :destroy

  has_many :financial_entries,
           through: :financial_entry_allocations

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