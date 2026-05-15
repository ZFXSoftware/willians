# app/models/tenant.rb

class Tenant < ApplicationRecord
  has_many :platform_accounts, dependent: :destroy
  has_many :orders, dependent: :destroy
  has_many :invoices, dependent: :destroy
  has_many :financial_entries, dependent: :destroy
  has_many :financial_entry_allocations, dependent: :destroy
  has_many :omie_financial_mappings, dependent: :destroy
  has_many :conciliation_runs, dependent: :destroy
  has_many :divergence_reports, dependent: :destroy

  enum :status, {
    active: "active",
    inactive: "inactive",
    blocked: "blocked"
  }

  validates :name, presence: true
end