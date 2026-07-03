class ConciliationRun < ApplicationRecord
  belongs_to :tenant,
             optional: true

  belongs_to :platform_account,
             optional: true

  has_many :conciliacao_registros,
           dependent: :destroy

  enum :status, {
    pending: "pending",
    processing: "processing",
    completed: "completed",
    failed: "failed"
  }
end