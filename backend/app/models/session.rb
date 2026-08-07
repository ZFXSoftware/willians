require "digest"

# Sessão de API com token opaco.
#
# O token só existe em claro na resposta do login; o banco guarda apenas o
# SHA-256. Isso permite revogação real (logout, expiração, corte administrativo)
# sem depender de expiração embutida em um JWT que não dá para cancelar.
class Session < ApplicationRecord
  DEFAULT_TTL = 14.days

  # Evita um UPDATE por requisição só para registrar o último uso.
  TOUCH_THROTTLE = 5.minutes

  belongs_to :user

  attr_accessor :raw_token

  scope :active, -> {
    where(revoked_at: nil).where(expires_at: Time.current..)
  }

  def self.digest_for(raw_token)
    Digest::SHA256.hexdigest(raw_token.to_s)
  end

  def self.issue!(user:, ip_address: nil, user_agent: nil, ttl: DEFAULT_TTL)
    raw_token = SecureRandom.urlsafe_base64(32)

    session = create!(
      user: user,

      token_digest: digest_for(raw_token),

      expires_at: ttl.from_now,

      last_used_at: Time.current,

      ip_address: ip_address,

      user_agent: user_agent
    )

    session.raw_token = raw_token

    session
  end

  def self.authenticate(raw_token)
    return if raw_token.blank?

    active
      .includes(:user)
      .find_by(token_digest: digest_for(raw_token))
  end

  def revoke!
    update_columns(
      revoked_at: Time.current,
      updated_at: Time.current
    )
  end

  def touch_usage!
    return if last_used_at.present? && last_used_at > TOUCH_THROTTLE.ago

    update_columns(
      last_used_at: Time.current,
      updated_at: Time.current
    )
  end

  def expired?
    expires_at <= Time.current
  end
end
