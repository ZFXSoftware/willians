require "test_helper"

# Percurso completo: ingestão -> recebível -> repasse -> conciliação -> saldo.
# É o teste que segura o produto: cada etapa consome o que a anterior gravou.
class FluxoConciliacaoTest < ActiveSupport::TestCase
  setup do
    @tenant = criar_tenant
    @conta = criar_conta(tenant: @tenant, external_id: "demo-ml-001")
    @hoje = Date.current
    @de = @hoje - 30
    @ate = @hoje - 25

    @resumo_ingestao = com_env("MARKETPLACE_SIMULATION" => "true") { ingerir }
  end

  def ingerir
    Marketplace::Ingestors::MarketplaceIngestor.new(
      tenant: @tenant, platform_account: @conta, start_date: @de, end_date: @ate
    ).call
  end

  def lancamentos = FinancialEntry.where(tenant: @tenant)

  def recebiveis = ReceivableUnit.where(tenant: @tenant)

  def alocacoes = FinancialEntryAllocation.where(tenant: @tenant)

  def repassar(referencia, dias_atras)
    Financeiro::PayoutEngine.new(
      tenant: @tenant, platform_account: @conta,
      payout_reference: referencia, paid_at: (@hoje - dias_atras).to_time
    ).call
  end

  # Títulos forjados no formato do OMIE. O recebível indicado sai 10% menor,
  # para exercitar o caminho de divergência.
  def titulos_omie(divergente: nil)
    recebiveis.order(:id).map do |r|
      valor = r.id == divergente&.id ? (r.gross_amount * BigDecimal("0.90")).round(2) : r.gross_amount

      { "codigo_lancamento_integracao" => r.external_id,
        "numero_documento" => r.external_id,
        "valor_documento" => valor.to_f }
    end
  end

  def conciliar(titulos)
    Conciliacao::ConciliacaoService.new(
      omie_client: Omie::FakeOmieClient.new(titulos: titulos),
      tenant: @tenant, platform_account: @conta,
      start_date: @hoje - 20, end_date: @hoje
    ).processar
  end

  # ----------------------------------------------------------------- ingestão

  test "ingestão cria um lançamento por evento, vinculado a pedido" do
    assert_operator @resumo_ingestao[:received], :>, 0
    assert_equal @resumo_ingestao[:received], @resumo_ingestao[:created]
    assert_equal 0, @resumo_ingestao[:failed]
    assert_operator Order.where(tenant: @tenant).count, :>, 0
    assert_equal 0, lancamentos.where(order_id: nil).count, "todo lançamento precisa de pedido"
    assert_operator lancamentos.sales.count, :>, 0
    assert_operator lancamentos.fees.count, :>, 0
  end

  test "reingestão do mesmo período não duplica lançamento" do
    repetida = com_env("MARKETPLACE_SIMULATION" => "true") { ingerir }

    assert_equal 0, repetida[:created]
    assert_equal repetida[:received], repetida[:skipped]
  end

  # ---------------------------------------------------------------- recebíveis

  test "recebível nasce com a taxa já descontada" do
    assert_equal lancamentos.sales.count, recebiveis.count, "um recebível por venda"
    assert_equal recebiveis.count, recebiveis.where("fee_amount > 0").count

    recebiveis.each do |r|
      assert_equal r.gross_amount - r.fee_amount, r.net_amount,
                   "líquido do recebível ##{r.id} não foi recomputado após a taxa"
    end
  end

  test "toda venda e taxa fica alocada, com tenant e valor" do
    assert_equal lancamentos.count, alocacoes.where(allocation_type: :receivable).count
    assert_equal 0, alocacoes.where(tenant_id: nil).count
    assert_equal 0, alocacoes.where(allocated_amount: nil).count
  end

  # ------------------------------------------------------------------ repasses

  test "repasses liquidam os recebíveis e são idempotentes" do
    a = repassar("PAYOUT-DEMO-A", 13)
    b = repassar("PAYOUT-DEMO-B", 10)

    assert_equal 2, PayoutBatch.where(tenant: @tenant).count
    assert [a, b].all? { |p| p.financial_entry_id.present? }, "repasse precisa do lançamento de liquidação"
    assert_equal recebiveis.count, ReceivableUnit.where(tenant: @tenant, status: :paid).count
    assert_operator alocacoes.where(allocation_type: :payout).count, :>, 0

    repetido = repassar("PAYOUT-DEMO-A", 13)

    assert_equal a.id, repetido.id
    assert_equal 2, PayoutBatch.where(tenant: @tenant).count
  end

  # --------------------------------------------------------------- conciliação

  test "conciliação separa o que bate do que diverge" do
    repassar("PAYOUT-DEMO-A", 13)
    b = repassar("PAYOUT-DEMO-B", 10)

    divergente = ReceivableUnit.joins(:financial_entry_allocations)
                               .where(financial_entry_allocations: { payout_batch_id: b.id })
                               .distinct.order(:id).first

    conciliar(titulos_omie(divergente: divergente))

    run = ConciliationRun.where(tenant: @tenant).order(:id).last
    registros = ConciliacaoRegistro.where(tenant: @tenant)

    assert_equal "completed", run.status
    assert_equal @tenant.id, run.tenant_id
    assert_equal @conta.platform, run.platform
    assert_equal 2, run.total_entries, "dois repasses processados"
    assert_equal 1, run.matches_found
    assert_equal 1, run.divergences_found

    assert_equal 2, registros.count
    assert_equal 0, registros.where(valor: nil).count
    assert_equal 100, registros.find_by(status: "matched").confidence_score
    assert registros.find_by(status: "divergent").diferenca.to_d.nonzero?, "divergente sem diferença"

    assert_equal 1, DivergenceReport.where(tenant: @tenant, status: :open).count
  end

  test "reconciliar não duplica divergência já aberta" do
    repassar("PAYOUT-DEMO-A", 13)
    b = repassar("PAYOUT-DEMO-B", 10)

    divergente = ReceivableUnit.joins(:financial_entry_allocations)
                               .where(financial_entry_allocations: { payout_batch_id: b.id })
                               .distinct.order(:id).first
    titulos = titulos_omie(divergente: divergente)

    conciliar(titulos)
    antes = DivergenceReport.where(tenant: @tenant).count
    conciliar(titulos)

    assert_equal antes, DivergenceReport.where(tenant: @tenant).count
    assert_equal 2, ConciliationRun.where(tenant: @tenant).count, "cada execução deixa sua run"
  end

  # ------------------------------------------------------------------- saldos

  test "saldo reflete as liquidações e o snapshot é gravado" do
    repassar("PAYOUT-DEMO-A", 13)

    saldo = Financeiro::BalanceEngine.new(tenant: @tenant, platform_account: @conta).call

    assert_operator saldo[:available_balance], :>, 0
    assert Financeiro::BalanceSnapshotEngine.new(tenant: @tenant, platform_account: @conta).call.persisted?
  end
end
