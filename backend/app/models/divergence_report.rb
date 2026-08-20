# app/models/divergence_report.rb

class DivergenceReport < ApplicationRecord
  belongs_to :tenant

  # Opcional porque nem toda divergência é de um lançamento: a diferença entre
  # o saldo da plataforma e o nosso (briefing 2.4) é da conta inteira.
  belongs_to :financial_entry, optional: true

  enum :status, {
    open: "open",
    analyzing: "analyzing",
    resolved: "resolved",
    ignored: "ignored"
  }

  validates :divergence_type,
            presence: true
end