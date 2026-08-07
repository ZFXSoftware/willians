class OauthState < ApplicationRecord
  TTL = 15.minutes

  belongs_to :tenant

  belongs_to :user

  belongs_to :platform_account, optional: true

  validates :state, presence: true, uniqueness: true

  validates :platform, presence: true

  scope :usable, -> {
    where(consumed_at: nil).where(expires_at: Time.current..)
  }

  def self.issue!(platform:, tenant:, user:, platform_account: nil, code_verifier: nil)
    create!(
      state: SecureRandom.urlsafe_base64(32),
      platform: platform,
      tenant: tenant,
      user: user,
      platform_account: platform_account,
      code_verifier: code_verifier,
      expires_at: TTL.from_now
    )
  end

  # Uso único: consome dentro de uma transação com lock, para que um replay do
  # callback não valha uma segunda vez.
  def self.consume!(state)
    return if state.blank?

    transaction do
      record = usable.lock.find_by(state: state)

      next if record.blank?

      record.update!(consumed_at: Time.current)

      record
    end
  end
end
