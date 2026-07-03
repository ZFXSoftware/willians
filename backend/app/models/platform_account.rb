# app/models/platform_account.rb

class PlatformAccount < ApplicationRecord
  belongs_to :tenant

  has_many :orders, dependent: :destroy
  has_many :financial_entries, dependent: :destroy

  enum :status, {
    active: "active",
    inactive: "inactive",
    error: "error"
  }

  enum :provider, {
    mercado_livre: "mercado_livre",
    shopee: "shopee",
    amazon: "amazon"
  }

  validates :name, presence: true
  validates :platform, presence: true
end