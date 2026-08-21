class User < ApplicationRecord
  has_secure_password

  has_many :sessions, dependent: :destroy

  has_many :tenant_users, dependent: :destroy

  # Convites que esta pessoa gerou: o vínculo é só para auditoria, então
  # apagar quem convidou não pode apagar o convite.
  has_many :convites_enviados, class_name: "Convite", foreign_key: :convidado_por_id, dependent: :nullify, inverse_of: :convidado_por

  has_many :tenants, through: :tenant_users

  enum :status, {
    active: "active",
    suspended: "suspended"
  }

  normalizes :email, with: ->(email) { email.to_s.strip.downcase }

  validates :name,
            presence: true

  validates :email,
            presence: true,
            uniqueness: { case_sensitive: false },
            format: { with: URI::MailTo::EMAIL_REGEXP }

  # allow_nil deixa atualizar o usuário sem reenviar a senha; has_secure_password
  # já exige a senha na criação.
  validates :password,
            length: { minimum: 8 },
            allow_nil: true

  def membership_for(tenant)
    return if tenant.blank?

    tenant_users.find_by(tenant_id: tenant.is_a?(Tenant) ? tenant.id : tenant)
  end

  def member_of?(tenant)
    membership_for(tenant).present?
  end
end
