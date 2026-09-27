class ReceivableUnit < ApplicationRecord
  belongs_to :tenant

  belongs_to :platform_account,
             optional: true

  belongs_to :order,
             optional: true

  belongs_to :invoice,
             optional: true

  has_many :financial_entry_allocations,
           dependent: :destroy

  has_many :financial_entries,
           through: :financial_entry_allocations

  # Mesma razão do ConciliacaoRegistro: o registro de conciliação sobrevive ao
  # título, sem o vínculo. Sem esta linha o destroy da unidade batia na FK.
  has_many :conciliacao_registros,
           dependent: :nullify,
           inverse_of: :receivable_unit

  enum :status, {
    pending: "pending",
    scheduled: "scheduled",
    partially_paid: "partially_paid",
    available: "available",
    paid: "paid",
    blocked: "blocked",
    disputed: "disputed",
    cancelled: "cancelled"
  }

  # Recebível que nasceu de linha que NÃO é venda.
  #
  # Aconteceu por regressão: ao acrescentar `RECORD_TYPE` ao relatório, toda linha
  # passou a ser classificada como `release` e virou venda — reserva de disputa,
  # frete, cashback. A limpeza pegou 3.379 e sobraram 270, R$ 40.011,06, dos quais
  # 263 dentro de repasse. Eram quase toda a diferença que a conciliação acusava.
  #
  # Marcados e NÃO apagados: são o registro do que aconteceu, e apagar lançamento
  # financeiro para consertar número é o hábito que esta base não pode ter. Quem
  # soma — repasse e conciliação — usa `vendas_reais`.
  MARCA_NAO_E_VENDA = "nao_e_venda".freeze

  scope :vendas_reais, lambda {
    where("NOT jsonb_exists(COALESCE(receivable_units.metadata, '{}'::jsonb), ?)", MARCA_NAO_E_VENDA)
  }

  def nao_e_venda? = (metadata || {}).key?(MARCA_NAO_E_VENDA)

  validates :gross_amount,
            presence: true

  validates :net_amount,
            presence: true

  scope :scheduled_for_payment, ->(date) {
    where(
      status: :scheduled,
      expected_on: ..date
    )
  }
end
