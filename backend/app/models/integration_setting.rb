# Uma chave de configuração de integração, por tenant.
#
# Uma linha por campo (e não um JSON por provedor) porque assim a gravação é
# parcial por natureza, a auditoria é por campo e o índice único impede
# duplicata sem código.
class IntegrationSetting < ApplicationRecord
  belongs_to :tenant

  belongs_to :updated_by, class_name: "User", optional: true

  encrypts :value

  validates :provider, presence: true

  validates :key,
            presence: true,
            uniqueness: { scope: %i[tenant_id provider] }

  scope :for_provider, ->(provider) { where(provider: provider.to_s) }

  def self.valores(tenant, provider)
    return {} if tenant.blank?

    for_provider(provider)
      .where(tenant_id: tenant.id)
      .pluck(:key, :value)
      .to_h
  end
end
