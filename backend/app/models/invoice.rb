# app/models/invoice.rb

class Invoice < ApplicationRecord
  belongs_to :tenant

  belongs_to :order

  has_many :financial_entries,
           dependent: :nullify

  has_many :financial_entry_allocations,
           dependent: :nullify

  enum :status, {
    issued: "issued",
    cancelled: "cancelled",
    denied: "denied",
    refunded: "refunded"
  }

  enum :operation_type, {
    sale: "sale",
    refund: "refund",
    adjustment: "adjustment"
  }

  validates :number,
            presence: true
end