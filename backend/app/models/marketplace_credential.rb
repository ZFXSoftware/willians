class MarketplaceCredential < ApplicationRecord
  # Margem para renovar antes de expirar: uma requisição que começa válida não
  # pode terminar com token vencido.
  REFRESH_MARGIN = 10.minutes

  belongs_to :tenant

  belongs_to :platform_account

  encrypts :access_token

  encrypts :refresh_token

  enum :status, {
    connected: "connected",
    expired: "expired",
    revoked: "revoked"
  }

  validates :platform, presence: true

  scope :refreshable, -> {
    connected.where(expires_at: ..REFRESH_MARGIN.from_now)
  }

  def expired?
    expires_at.blank? || expires_at <= Time.current
  end

  def needs_refresh?
    expires_at.blank? || expires_at <= REFRESH_MARGIN.from_now
  end

  def usable?
    connected? && access_token.present?
  end

  def mark_refresh_failure!(error)
    update!(
      status: :expired,
      refresh_failed_at: Time.current,
      refresh_error: error.to_s.truncate(500)
    )
  end
end
