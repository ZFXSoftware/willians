# Contexto da requisição (ou do job). Existe por causa das credenciais de
# integração: elas passaram a viver por tenant, e os clientes de API são
# construídos fundo na pilha, longe de quem conhece o tenant.
class Current < ActiveSupport::CurrentAttributes
  attribute :tenant

  attribute :user

  # Cache das configurações já lidas nesta requisição: sem ele, cada campo
  # consultado vira um SELECT e uma decifragem.
  attribute :integration_settings

  def self.with_tenant(tenant)
    anterior = self.tenant
    anteriores = integration_settings

    self.tenant = tenant
    self.integration_settings = nil

    yield
  ensure
    self.tenant = anterior
    self.integration_settings = anteriores
  end

  def self.settings_cache
    self.integration_settings ||= {}
  end
end
