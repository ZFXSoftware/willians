# app/models/tenant.rb

class Tenant < ApplicationRecord
  # Destruído junto com a empresa, e não órfão: é a identidade digital dela.
  # Certificado sobrevivente a uma empresa apagada é chave privada sem dono no
  # banco — o pior tipo de resíduo.
  has_one :certificado_digital, dependent: :destroy

  # Some com a empresa: é marcador de leitura dela, e não faz sentido sozinho.
  has_one :leitura_sefaz, dependent: :destroy

  has_many :tenant_users, dependent: :destroy
  has_many :users, through: :tenant_users
  has_many :platform_accounts, dependent: :destroy
  has_many :orders, dependent: :destroy
  has_many :invoices, dependent: :destroy
  has_many :financial_entries, dependent: :destroy
  has_many :financial_entry_allocations, dependent: :destroy
  has_many :omie_financial_mappings, dependent: :destroy
  has_many :conciliation_runs, dependent: :destroy
  has_many :divergence_reports, dependent: :destroy
  has_many :receivable_units, dependent: :destroy
  has_many :payout_batches, dependent: :destroy
  has_many :platform_balance_snapshots, dependent: :destroy
  has_many :marketplace_credentials, dependent: :destroy
  has_many :conciliacao_registros, dependent: :destroy
  has_many :oauth_states, dependent: :destroy
  has_many :integration_settings, dependent: :destroy
  has_many :devolucoes, dependent: :destroy
  has_many :convites, dependent: :destroy

  enum :status, {
    active: "active",
    inactive: "inactive",
    blocked: "blocked"
  }

  validates :name, presence: true
end
