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

  # Recusa DEFINITIVA: o refresh_token não vale mais e o lojista precisa
  # autorizar de novo. Só quem sabe disso é a plataforma, dizendo invalid_grant
  # — ver Marketplace::RecusaDefinitiva.
  def mark_refresh_failure!(error)
    update!(
      status: :expired,
      refresh_failed_at: Time.current,
      refresh_error: error.to_s.truncate(500)
    )
  end

  # Falha passageira: guarda o motivo para aparecer na tela e MANTÉM a conta
  # conectada. Um 500 da plataforma não pode custar um OAuth novo ao lojista.
  def mark_refresh_retry!(error)
    update!(
      refresh_failed_at: Time.current,
      refresh_error: error.to_s.truncate(500)
    )
  end
end
