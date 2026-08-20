require "test_helper"

module Financeiro
  # Briefing 2.8. O razão já registrava o dinheiro voltando, mas solto: não
  # dava para dizer de qual venda veio nem se a NF de devolução saiu. O risco
  # aqui é dar a devolução por concluída sem que o ciclo tenha fechado.
  class RastreioDeDevolucoesTest < ActiveSupport::TestCase
    setup do
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant)
    end

    def estorno(tipo: :refund, valor: 40, pedido: nil, external_id: nil)
      criar_lancamento(tenant: @tenant, conta: @conta, tipo: tipo, direcao: :debit,
                       valor: valor, pedido: pedido, external_id: external_id || "MLREL-#{SecureRandom.hex(3)}",
                       ocorrido_em: 2.days.ago)
    end

    def rodar = RastreioDeDevolucoes.new(tenant: @tenant).call

    test "estorno sem pedido fica visível como sem origem" do
      estorno

      assert_equal 1, rodar[:resumo][:sem_origem]

      devolucao = Devolucao.find_by!(tenant_id: @tenant.id)

      assert devolucao.sem_origem?
      assert_nil devolucao.order_id
      assert_equal BigDecimal("40"), devolucao.amount
    end

    test "com pedido mas sem NF de venda, fica aberta" do
      pedido = criar_pedido(tenant: @tenant, conta: @conta)
      estorno(pedido: pedido)

      assert_equal 1, rodar[:resumo][:aberta]
      assert_equal pedido.id, Devolucao.find_by!(tenant_id: @tenant.id).order_id
    end

    test "com a NF de venda, passa a esperar a NF de devolução" do
      pedido = criar_pedido(tenant: @tenant, conta: @conta)
      nota = criar_nota(tenant: @tenant, pedido: pedido, numero: "000900100")
      estorno(pedido: pedido)

      assert_equal 1, rodar[:resumo][:aguardando_nota]

      devolucao = Devolucao.find_by!(tenant_id: @tenant.id)

      assert_equal nota.id, devolucao.invoice_id, "achou a venda de origem"
      assert_nil devolucao.return_invoice_id
      assert devolucao.rastreada?
    end

    test "com a NF de devolução emitida, o ciclo fecha" do
      pedido = criar_pedido(tenant: @tenant, conta: @conta)
      venda = criar_nota(tenant: @tenant, pedido: pedido, numero: "000900100")
      devolucao_nf = criar_nota(tenant: @tenant, pedido: pedido, numero: "000900200",
                                external_id: "tiny-devolucao")
      devolucao_nf.update!(operation_type: :refund)

      estorno(pedido: pedido)

      assert_equal 1, rodar[:resumo][:concluida]

      registro = Devolucao.find_by!(tenant_id: @tenant.id)

      assert registro.concluida?
      assert_equal venda.id, registro.invoice_id, "a NF de venda de origem"
      assert_equal devolucao_nf.id, registro.return_invoice_id, "a NF de devolução"
      assert registro.resolved_at.present?
    end

    test "a NF de devolução não é confundida com a de venda" do
      pedido = criar_pedido(tenant: @tenant, conta: @conta)
      criar_nota(tenant: @tenant, pedido: pedido, numero: "000900200",
                 external_id: "tiny-dev").update!(operation_type: :refund)

      estorno(pedido: pedido)
      rodar

      registro = Devolucao.find_by!(tenant_id: @tenant.id)

      # Sem NF de venda, o ciclo não pode ser dado por concluído só porque
      # existe uma nota de entrada.
      assert registro.aberta?, "estava #{registro.status}"
      assert_nil registro.invoice_id
    end

    test "disputa e chargeback são distinguidos do estorno comum" do
      pedido = criar_pedido(tenant: @tenant, conta: @conta)

      estorno(tipo: :refund, pedido: pedido, external_id: "E-1")
      estorno(tipo: :dispute, pedido: pedido, external_id: "E-2")
      estorno(tipo: :chargeback, pedido: pedido, external_id: "E-3")

      rodar

      assert_equal %w[chargeback devolucao disputa],
                   Devolucao.where(tenant_id: @tenant.id).pluck(:kind).sort
    end

    test "reexecutar avança o estado em vez de duplicar" do
      pedido = criar_pedido(tenant: @tenant, conta: @conta)
      lancamento = estorno(pedido: pedido)

      rodar

      assert Devolucao.find_by!(external_id: lancamento.external_id).aberta?

      criar_nota(tenant: @tenant, pedido: pedido, numero: "000900100")
      rodar

      assert_equal 1, Devolucao.where(tenant_id: @tenant.id).count
      assert Devolucao.find_by!(external_id: lancamento.external_id).aguardando_nota?
    end

    test "abertura preserva a data do primeiro registro" do
      pedido = criar_pedido(tenant: @tenant, conta: @conta)
      estorno(pedido: pedido)

      rodar
      abertura = Devolucao.find_by!(tenant_id: @tenant.id).opened_at

      criar_nota(tenant: @tenant, pedido: pedido, numero: "000900100")
      rodar

      assert_equal abertura, Devolucao.find_by!(tenant_id: @tenant.id).opened_at
    end

    test "venda comum não vira devolução" do
      criar_lancamento(tenant: @tenant, conta: @conta, tipo: :sale, direcao: :credit,
                       valor: 100, ocorrido_em: 2.days.ago)

      assert_equal 0, rodar[:resumo][:total]
      assert_equal 0, Devolucao.count
    end
  end
end
