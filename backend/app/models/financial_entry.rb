# app/models/financial_entry.rb

class FinancialEntry < ApplicationRecord
  belongs_to :tenant

  belongs_to :platform_account,
             optional: true

  belongs_to :order,
             optional: true

  belongs_to :invoice,
             optional: true

  belongs_to :conciliacao_registro,
             optional: true

  has_many :financial_entry_allocations,
           dependent: :destroy

  has_one :omie_financial_mapping,
          dependent: :destroy

  has_many :divergence_reports,
           dependent: :destroy

  enum :entry_type, {
    sale: "sale",
    fee: "fee",
    settlement: "settlement",
    refund: "refund",
    dispute: "dispute",
    chargeback: "chargeback",
    transfer: "transfer",
    payment: "payment",
    adjustment: "adjustment",
    future_receivable: "future_receivable",
    unidentified: "unidentified"
  }

  enum :status, {
    pending: "pending",
    processing: "processing",
    settled: "settled",
    cancelled: "cancelled",
    disputed: "disputed"
  }

  validates :external_id,
            presence: true

  validates :amount,
            presence: true
end