class FinancialEntryAllocation < ApplicationRecord
  belongs_to :financial_entry

  belongs_to :receivable_unit,
             optional: true

  belongs_to :payout_batch,
             optional: true

  enum :allocation_type, {
    receivable: "receivable",
    payout: "payout",
    adjustment: "adjustment"
  }

  validates :amount,
            presence: true
end