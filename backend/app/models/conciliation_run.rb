# app/models/conciliation_run.rb

class ConciliationRun < ApplicationRecord
  belongs_to :tenant

  enum :status, {
    pending: "pending",
    running: "running",
    completed: "completed",
    failed: "failed"
  }

  validates :platform,
            presence: true
end