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

  belongs_to :reversal_of,
             class_name: "FinancialEntry",
             optional: true

  has_many :reversals,
           class_name: "FinancialEntry",
           foreign_key: :reversal_of_id,
           dependent: :nullify

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

  enum :direction, {
    credit: "credit",
    debit: "debit"
  }

  enum :source, {
    mercado_livre: "mercado_livre",
    shopee: "shopee",
    amazon: "amazon",
    omie: "omie",
    manual: "manual"
  }

  validates :external_id,
            presence: true

  validates :amount,
            presence: true

  validates :direction,
            presence: true

  validates :occurred_at,
            presence: true

  before_update :prevent_immutable_changes

  scope :credits, -> {
    where(direction: :credit)
  }

  scope :debits, -> {
    where(direction: :debit)
  }

  scope :sales, -> {
    where(entry_type: :sale)
  }

  scope :fees, -> {
    where(entry_type: :fee)
  }

  scope :refunds, -> {
    where(entry_type: :refund)
  }

  scope :chargebacks, -> {
    where(entry_type: :chargeback)
  }

  scope :settled, -> {
    where(status: :settled)
  }

  scope :disputed, -> {
    where(status: :disputed)
  }

  after_commit :generate_receivable!,
             on: :create

  def immutable?
    immutable
  end

  def lock!
    update_column(:immutable, true)
  end

  def generate_receivable!
    return unless sale?

    Financeiro::ReceivableEngine
      .new(
        financial_entry: self
      )
      .call
  end

  def reverse!(reason: nil)
    self.class.create!(
      tenant: tenant,
      platform_account: platform_account,
      order: order,
      invoice: invoice,
      conciliacao_registro: conciliacao_registro,

      reversal_of: self,

      entry_type: :adjustment,
      status: :settled,

      direction: reverse_direction,

      amount: amount,

      source: source,

      occurred_at: Time.current,

      available_on: Date.current,

      raw_payload: {
        reversal_reason: reason,
        reversed_entry_id: id
      }
    )
  end

  private

  def reverse_direction
    credit? ? :debit : :credit
  end

  def prevent_immutable_changes
    return unless immutable?

    protected_fields = [
      "amount",
      "direction",
      "entry_type",
      "source",
      "tenant_id"
    ]

    changed_protected_fields =
      changes.keys & protected_fields

    if changed_protected_fields.any?
      errors.add(
        :base,
        "Immutable financial entries cannot be modified"
      )

      throw(:abort)
    end
  end
end