require "digest"

# Convite de acesso a uma empresa, entregue como link.
#
# Mesmo desenho da Session: o token só existe em claro no instante em que é
# gerado, e o banco guarda apenas o SHA-256. Assim o link é revogável de
# verdade, e vazar o banco não produz convites utilizáveis.
class Convite < ApplicationRecord
  self.table_name = "convites"

  DEFAULT_TTL = 7.days

  belongs_to :tenant

  belongs_to :convidado_por, class_name: "User", optional: true

  attr_accessor :raw_token

  enum :role, {
    owner: "owner",
    admin: "admin",
    member: "member",
    viewer: "viewer"
  }, prefix: :papel

  validates :email, presence: true

  scope :pendentes, -> {
    where(accepted_at: nil, revoked_at: nil).where(expires_at: Time.current..)
  }

  def self.digest_for(raw_token) = Digest::SHA256.hexdigest(raw_token.to_s)

  def self.emitir!(tenant:, email:, role:, convidado_por: nil, ttl: DEFAULT_TTL)
    raw = SecureRandom.urlsafe_base64(32)

    convite = create!(
      tenant: tenant,
      email: email.to_s.strip.downcase,
      role: role,
      convidado_por: convidado_por,
      token_digest: digest_for(raw),
      expires_at: ttl.from_now
    )

    convite.raw_token = raw

    convite
  end

  # Busca só o que ainda vale. Um convite usado, revogado ou vencido é tratado
  # como inexistente — quem tem o link não descobre nem que ele existiu.
  def self.valido(raw_token)
    return if raw_token.blank?

    pendentes.find_by(token_digest: digest_for(raw_token))
  end

  def aceito? = accepted_at.present?

  def revogado? = revoked_at.present?

  def expirado? = expires_at <= Time.current

  def pendente? = !aceito? && !revogado? && !expirado?

  def situacao
    return "aceito" if aceito?

    return "revogado" if revogado?

    return "expirado" if expirado?

    "pendente"
  end
end
