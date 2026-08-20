require "test_helper"

class TenantTest < ActiveSupport::TestCase
  test "monta o cenário mínimo e apaga o grafo inteiro" do
    tenant = criar_tenant
    conta = criar_conta(tenant: tenant)
    pedido = criar_pedido(tenant: tenant, conta: conta)
    criar_recebivel(tenant: tenant, conta: conta, pedido: pedido)
    IntegrationSetting.create!(tenant: tenant, provider: "omie", key: "app_key", value: "x")

    assert_equal 1, tenant.platform_accounts.count

    # Apagar precisa funcionar: faltavam associações e a foreign key barrava.
    assert_nothing_raised { tenant.destroy! }
    assert_equal 0, ReceivableUnit.where(tenant_id: tenant.id).count
    assert_equal 0, IntegrationSetting.where(tenant_id: tenant.id).count
  end
end
