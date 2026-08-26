# app/models/order.rb

class Order < ApplicationRecord
  belongs_to :tenant

  belongs_to :platform_account,
             optional: true

  # NULLIFY, e nunca destroy: a nota fiscal é documento do FISCO, não nosso.
  #
  # O pedido aqui é uma conveniência — um registro que criamos para amarrar as
  # pontas. Apagar uma conta de marketplace conectada por engano apagava os
  # pedidos dela, e os pedidos levavam as notas fiscais junto: 4051 documentos
  # sumindo por causa de um OAuth errado. A nota sobrevive ao pedido e é
  # reencontrada por ele quando ele voltar.
  has_many :invoices, dependent: :nullify

  has_many :devolucoes, dependent: :nullify

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