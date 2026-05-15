# app/models/financial_entry_allocation.rb

class FinancialEntryAllocation < ApplicationRecord
  belongs_to :tenant

  belongs_to :financial_entry

  belongs_to :invoice,
             optional: true

  belongs_to :order,
             optional: true

  validates :allocated_amount,
            presence: true

  enum :allocation_type, {
    settlement: "settlement",
    refund: "refund",
    fee: "fee",
    adjustment: "adjustment"
  }
end