# app/models/order.rb

class Order < ApplicationRecord
  belongs_to :tenant

  belongs_to :platform_account,
             optional: true

  has_many :invoices, dependent: :destroy

  has_many :financial_entries,
           dependent: :nullify

  has_many :financial_entry_allocations,
           dependent: :nullify

  # Sem isto, apagar um pedido deixa recebíveis apontando para ele e a foreign
  # key barra a exclusão.
  has_many :receivable_units,
           dependent: :nullify

  enum :status, {
    pending: "pending",
    approved: "approved",
    shipped: "shipped",
    delivered: "delivered",
    cancelled: "cancelled",
    refunded: "refunded",
    disputed: "disputed"
  }

  validates :external_id,
            presence: true

  validates :platform,
            presence: true
end