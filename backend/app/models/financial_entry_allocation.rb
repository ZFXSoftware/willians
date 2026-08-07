class FinancialEntryAllocation < ApplicationRecord
  belongs_to :tenant

  belongs_to :financial_entry

  belongs_to :receivable_unit,
             optional: true

  belongs_to :payout_batch,
             optional: true

  belongs_to :order,
             optional: true

  belongs_to :invoice,
             optional: true

  enum :allocation_type, {
    receivable: "receivable",
    payout: "payout",
    adjustment: "adjustment"
  }

  validates :allocation_type,
            presence: true

  validates :allocated_amount,
            presence: true
end
