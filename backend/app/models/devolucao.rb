# Uma devolução ou disputa, rastreada da abertura até o ajuste financeiro.
#
# O razão já registrava o dinheiro voltando (refund, dispute, chargeback), mas
# solto: não dava para dizer de qual venda veio, se a NF de devolução foi
# emitida, nem se o ajuste chegou ao OMIE. É esse fio que este registro segura.
class Devolucao < ApplicationRecord
  self.table_name = "devolucoes"

  belongs_to :tenant

  belongs_to :platform_account, optional: true

  belongs_to :order, optional: true

  # A NF da VENDA que está sendo devolvida.
  belongs_to :invoice, optional: true

  # A NF de DEVOLUÇÃO (nota de entrada), quando emitida.
  belongs_to :return_invoice, class_name: "Invoice", optional: true

  has_many :financial_entries,
           -> { where(entry_type: %w[refund dispute chargeback]) },
           through: :order,
           source: :financial_entries

  enum :kind, {
    devolucao: "devolucao",
    disputa: "disputa",
    chargeback: "chargeback"
  }, prefix: :tipo

  # O ciclo que o briefing pede, em ordem:
  #
  #   aberta            o dinheiro voltou; ainda não sabemos de qual venda
  #   com_origem        achamos o pedido e a NF de venda
  #   aguardando_nota   falta a NF de devolução ser emitida
  #   concluida         NF de devolução emitida e ajuste refletido
  enum :status, {
    aberta: "aberta",
    com_origem: "com_origem",
    aguardando_nota: "aguardando_nota",
    concluida: "concluida",
    sem_origem: "sem_origem"
  }

  validates :external_id, presence: true, uniqueness: { scope: :tenant_id }

  scope :em_aberto, -> { where.not(status: :concluida) }

  def rastreada? = order_id.present? && invoice_id.present?
end
