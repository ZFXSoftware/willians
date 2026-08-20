# app/models/invoice.rb

class Invoice < ApplicationRecord
  belongs_to :tenant

  belongs_to :order

  has_many :financial_entries,
           dependent: :nullify

  has_many :financial_entry_allocations,
           dependent: :nullify

  has_many :receivable_units,
           dependent: :nullify

  # A NF pode ser a da venda devolvida ou a própria nota de devolução.
  has_many :devolucoes,
           dependent: :nullify

  has_many :devolucoes_como_nota_de_devolucao,
           class_name: "Devolucao",
           foreign_key: :return_invoice_id,
           dependent: :nullify,
           inverse_of: :return_invoice

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