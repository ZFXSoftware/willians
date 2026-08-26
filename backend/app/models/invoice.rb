# app/models/invoice.rb

class Invoice < ApplicationRecord
  belongs_to :tenant

  # Opcional porque a nota existe sem o nosso pedido: ela é documento do fisco,
  # e o pedido é registro nosso. Quem cria a nota (o InvoiceSync) sempre a
  # amarra a um pedido; isto aqui é para ela SOBREVIVER quando o pedido some.
  belongs_to :order, optional: true

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