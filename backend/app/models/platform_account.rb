# app/models/platform_account.rb

class PlatformAccount < ApplicationRecord
  belongs_to :tenant

  has_many :orders, dependent: :destroy
  has_many :financial_entries, dependent: :destroy
  has_many :receivable_units, dependent: :destroy
  has_many :payout_batches, dependent: :destroy
  has_many :conciliation_runs, dependent: :destroy
  has_many :platform_balance_snapshots, dependent: :destroy

  has_one :marketplace_credential, dependent: :destroy

  enum :status, {
    active: "active",
    inactive: "inactive",
    error: "error"
  }

  # A coluna é `platform`. Não existe `provider` no schema — o enum anterior
  # apontava para uma coluna inexistente e estourava em qualquer instanciação.
  enum :platform, {
    mercado_livre: "mercado_livre",
    shopee: "shopee",
    amazon: "amazon",
    magalu: "magalu"
  }

  validates :name, presence: true
  validates :platform, presence: true
end
