# app/models/divergence_report.rb

class DivergenceReport < ApplicationRecord
  belongs_to :tenant

  belongs_to :financial_entry

  enum :status, {
    open: "open",
    analyzing: "analyzing",
    resolved: "resolved",
    ignored: "ignored"
  }

  validates :divergence_type,
            presence: true
end