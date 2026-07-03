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