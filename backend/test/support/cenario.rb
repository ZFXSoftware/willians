# Construtores do cenário mínimo usado pelos testes.
#
# Cada teste monta o que precisa em vez de depender de fixtures compartilhadas:
# o que está sendo exercitado fica explícito na leitura, e um teste não
# contamina o outro.
module Cenario
  def criar_tenant(nome: "Tenant #{SecureRandom.hex(4)}", metadata: {})
    Tenant.create!(name: nome, status: :active, metadata: metadata)
  end

  def criar_usuario(tenant:, papel: :owner, email: nil)
    usuario = User.create!(
      name: "Usuário Teste",
      email: email || "u#{SecureRandom.hex(4)}@teste.local",
      password: "senha-de-teste-123",
      status: :active
    )

    TenantUser.create!(tenant: tenant, user: usuario, role: papel)

    usuario
  end

  def criar_conta(tenant:, plataforma: "mercado_livre", external_id: nil, metadata: {})
    PlatformAccount.create!(
      tenant: tenant,
      platform: plataforma,
      external_id: external_id || "acc-#{SecureRandom.hex(4)}",
      name: "Conta #{plataforma}",
      status: :active,
      metadata: metadata
    )
  end

  def criar_pedido(tenant:, conta:, external_id: nil)
    Order.create!(
      tenant: tenant,
      platform_account: conta,
      platform: conta.platform,
      external_id: external_id || "ped-#{SecureRandom.hex(4)}",
      status: :approved
    )
  end

  def criar_lancamento(tenant:, conta:, tipo: :sale, direcao: :credit, valor: 100,
                       pedido: nil, nota: nil, external_id: nil, ocorrido_em: Time.current,
                       status: :settled, disponivel_em: nil)
    FinancialEntry.create!(
      tenant: tenant, platform_account: conta, order: pedido, invoice: nota,
      external_id: external_id || "e-#{SecureRandom.hex(4)}",
      source: :manual, entry_type: tipo, direction: direcao, amount: valor,
      occurred_at: ocorrido_em, available_on: disponivel_em, status: status
    )
  end

  def criar_nota(tenant:, pedido:, numero:, valor: 100, external_id: nil)
    Invoice.create!(
      tenant: tenant, order: pedido, number: numero, series: "1",
      status: :issued, total_amount: valor, issued_at: Date.current,
      external_id: external_id || "tiny-#{numero}"
    )
  end

  def criar_recebivel(tenant:, conta:, pedido: nil, nota: nil, bruto: 100, liquido: 90,
                      status: :scheduled, previsto_para: nil, external_id: nil)
    ReceivableUnit.create!(
      tenant: tenant, platform_account: conta, order: pedido, invoice: nota,
      external_id: external_id || "r-#{SecureRandom.hex(4)}",
      gross_amount: bruto, net_amount: liquido, status: status, expected_on: previsto_para
    )
  end

  def criar_repasse(tenant:, conta:, external_id: nil, bruto: 100, liquido: 90,
                    pago_em: Time.current, lancamento: nil)
    PayoutBatch.create!(
      tenant: tenant, platform_account: conta, financial_entry: lancamento,
      external_id: external_id || "pay-#{SecureRandom.hex(4)}",
      status: :paid, gross_amount: bruto, net_amount: liquido, paid_at: pago_em
    )
  end

  def alocar!(tenant:, lancamento:, recebivel:, repasse: nil, tipo: :receivable)
    FinancialEntryAllocation.create!(
      tenant: tenant, financial_entry: lancamento, receivable_unit: recebivel,
      payout_batch: repasse, allocation_type: tipo,
      allocated_amount: lancamento.amount, amount: lancamento.amount
    )
  end

  # Executa o bloco com variáveis de ambiente trocadas e sempre restaura.
  def com_env(valores)
    anteriores = valores.keys.index_with { |k| ENV[k] }

    valores.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v.to_s }

    yield
  ensure
    anteriores.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end

# Troca um método de instância só durante o bloco. Existe porque alguns
# serviços constroem o próprio cliente HTTP internamente e não aceitam injeção;
# sem restaurar, o dublê vazaria para os outros testes.
module Cenario
  # O corpo novo vem como lambda; o bloco é o escopo em que ele vale.
  def com_metodo(klass, nome, corpo)
    original = klass.instance_method(nome) if klass.method_defined?(nome)

    klass.send(:define_method, nome, corpo)

    yield
  ensure
    klass.send(:remove_method, nome)

    klass.send(:define_method, nome, original) if original && original.owner == klass
  end
end
