class TenantUser < ApplicationRecord
  WRITE_ROLES = %w[owner admin].freeze

  belongs_to :tenant

  belongs_to :user

  enum :role, {
    owner: "owner",
    admin: "admin",
    member: "member",
    viewer: "viewer"
  }

  validates :user_id,
            uniqueness: { scope: :tenant_id }

  # Quem pode disparar operações que alteram dados (conciliação, sync).
  def can_write?
    WRITE_ROLES.include?(role)
  end
end
