class PlatformBalanceSnapshot < ApplicationRecord
  belongs_to :tenant

  belongs_to :platform_account

  validates :snapshot_date,
            presence: true
end