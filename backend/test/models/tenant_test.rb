require "test_helper"

class TenantTest < ActiveSupport::TestCase
  test "monta o cenário mínimo e apaga o grafo inteiro" do
    tenant = criar_tenant
    conta = criar_conta(tenant: tenant)
    pedido = criar_pedido(tenant: tenant, conta: conta)
    criar_recebivel(tenant: tenant, conta: conta, pedido: pedido)
    IntegrationSetting.create!(tenant: tenant, provider: "omie", key: "app_key", value: "x")
    nota = criar_nota(tenant: tenant, pedido: pedido, numero: "000900001")
    nota_de_devolucao = criar_nota(tenant: tenant, pedido: pedido, numero: "000900002",
                                   external_id: "tiny-dev")
    # As quatro chaves estrangeiras da devolução, de uma vez.
    Devolucao.create!(tenant: tenant, order: pedido, platform_account: conta,
                      invoice: nota, return_invoice: nota_de_devolucao,
                      external_id: "DEV-1", kind: "devolucao", status: "aberta")

    assert_equal 1, tenant.platform_accounts.count

    # Apagar precisa funcionar: faltavam associações e a foreign key barrava.
    assert_nothing_raised { tenant.destroy! }
    assert_equal 0, ReceivableUnit.where(tenant_id: tenant.id).count
    assert_equal 0, IntegrationSetting.where(tenant_id: tenant.id).count
    assert_equal 0, Devolucao.where(tenant_id: tenant.id).count
  end
end
