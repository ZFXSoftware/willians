require "test_helper"

module Financeiro
  # Briefing 2.4. A baixa pode estar certa em cada título e ainda assim faltar
  # dinheiro na conta, se algum evento não chegou. Esta é a conferência que
  # pega isso — e o erro mais perigoso aqui seria dizer "confere" quando na
  # verdade não houve com o que comparar.
  class ConciliacaoDeSaldoTest < ActiveSupport::TestCase
    setup do
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant)
    end

    # Deixa o nosso razão com saldo disponível conhecido.
    def com_saldo_interno(valor)
      criar_lancamento(tenant: @tenant, conta: @conta, tipo: :sale, direcao: :credit,
                       valor: valor, status: :settled)
    end

    def rodar(saldo_da_plataforma)
      resposta = if saldo_da_plataforma.nil?
                   ->(start_date:, end_date:) { nil }
                 else
                   ->(start_date:, end_date:) { saldo_da_plataforma }
                 end

      com_metodo(Marketplace::Providers::MercadoLivreProvider, :account_balance, resposta) do
        com_metodo(Marketplace::Providers::MercadoLivreProvider.singleton_class, :configured?, ->(_c) { true }) do
          ConciliacaoDeSaldo.new(tenant: @tenant).call
        end
      end
    end

    def plataforma(disponivel, total: nil)
      { available: BigDecimal(disponivel.to_s), future: nil,
        total: BigDecimal((total || disponivel).to_s), source: "relatorio_de_liberacoes" }
    end

    test "saldos iguais conferem e ficam registrados lado a lado" do
      com_saldo_interno(500)

      resultado = rodar(plataforma(500))
      detalhe = resultado[:detalhes].first

      assert_equal 1, resultado[:resumo][:confere]
      assert_equal :confere, detalhe[:situacao]
      assert_equal 0, detalhe[:diferenca]

      snapshot = PlatformBalanceSnapshot.find(detalhe[:snapshot_id])

      assert_equal BigDecimal("500"), snapshot.available_balance
      assert_equal BigDecimal("500"), snapshot.platform_available_balance
      assert_equal "relatorio_de_liberacoes", snapshot.platform_source
      assert_equal 0, DivergenceReport.where(tenant: @tenant).count
    end

    test "diferença abre divergência com os dois lados" do
      com_saldo_interno(500)

      resultado = rodar(plataforma(460))

      assert_equal 1, resultado[:resumo][:divergente]
      assert_equal BigDecimal("-40"), resultado[:detalhes].first[:diferenca]

      divergencia = DivergenceReport.find_by!(tenant_id: @tenant.id,
                                              divergence_type: ConciliacaoDeSaldo::TIPO_DIVERGENCIA)

      assert divergencia.open?
      assert_equal BigDecimal("460"), divergencia.expected_amount, "o que a plataforma diz"
      assert_equal BigDecimal("500"), divergencia.received_amount, "o que o nosso razão diz"
      assert_equal BigDecimal("-40"), divergencia.difference_amount
      assert_nil divergencia.financial_entry_id, "diferença de saldo não é de um lançamento"
      assert_equal @conta.id, divergencia.metadata["platform_account_id"]
    end

    test "centavos de arredondamento não viram divergência" do
      com_saldo_interno(500)

      assert_equal :confere, rodar(plataforma("499.98"))[:detalhes].first[:situacao]
      assert_equal 0, DivergenceReport.where(tenant: @tenant).count
    end

    test "sem o lado da plataforma não finge que conferiu" do
      com_saldo_interno(500)

      resultado = rodar(nil)
      detalhe = resultado[:detalhes].first

      assert_equal :sem_espelho, detalhe[:situacao]
      assert_includes detalhe[:mensagem], "não informou saldo"
      # O ponto: nada de snapshot "conferido" nem divergência inventada.
      assert_equal 0, PlatformBalanceSnapshot.where(platform_account_id: @conta.id).count
      assert_equal 0, DivergenceReport.where(tenant: @tenant).count
    end

    test "rodar de novo no mesmo dia atualiza em vez de empilhar" do
      com_saldo_interno(500)

      primeiro = rodar(plataforma(460))[:detalhes].first
      segundo = rodar(plataforma(450))[:detalhes].first

      assert_equal primeiro[:snapshot_id], segundo[:snapshot_id]
      assert_equal 1, PlatformBalanceSnapshot.where(platform_account_id: @conta.id).count
      assert_equal BigDecimal("-50"), PlatformBalanceSnapshot.find(segundo[:snapshot_id]).difference_amount
      assert_equal 1, DivergenceReport.where(tenant: @tenant).count, "uma divergência por conta, atualizada"
    end

    test "quando volta a bater, a divergência se resolve sozinha" do
      com_saldo_interno(500)

      rodar(plataforma(460))

      assert_equal 1, DivergenceReport.where(tenant: @tenant, status: :open).count

      rodar(plataforma(500))

      divergencia = DivergenceReport.find_by!(tenant_id: @tenant.id,
                                              divergence_type: ConciliacaoDeSaldo::TIPO_DIVERGENCIA)

      assert divergencia.resolved?
      assert divergencia.resolved_at.present?
      assert_includes divergencia.resolution_notes, "voltou a conferir"
    end

    # -------------------- plataforma que não tem "disponível" (Amazon)

    test "quando a plataforma só informa o futuro, é o futuro que é comparado" do
      pedido = criar_pedido(tenant: @tenant, conta: @conta)
      # Só o recebível em aberto: entra no nosso futuro, não no disponível.
      # (Um lançamento de venda geraria OUTRO recebível pelo after_commit do
      # FinancialEntry, e o futuro deixaria de ser 800.)
      criar_recebivel(tenant: @tenant, conta: @conta, pedido: pedido,
                      bruto: 800, liquido: 800, previsto_para: Date.current + 10)

      so_futuro = { available: nil, future: BigDecimal("800"),
                    total: BigDecimal("800"), source: "ciclo_aberto_amazon" }

      detalhe = rodar(so_futuro)[:detalhes].first

      assert_equal :confere, detalhe[:situacao],
                   "comparar o futuro da Amazon contra o nosso disponível inventaria divergência"
      assert_equal :future, detalhe[:base_da_comparacao]
      assert_equal BigDecimal("800"), detalhe[:saldo_interno]
    end

    test "diferença no futuro é divergência de verdade" do
      pedido = criar_pedido(tenant: @tenant, conta: @conta)
      criar_recebivel(tenant: @tenant, conta: @conta, pedido: pedido,
                      bruto: 800, liquido: 800, previsto_para: Date.current + 10)

      so_futuro = { available: nil, future: BigDecimal("700"),
                    total: BigDecimal("700"), source: "ciclo_aberto_amazon" }

      resultado = rodar(so_futuro)

      assert_equal 1, resultado[:resumo][:divergente]

      divergencia = DivergenceReport.find_by!(tenant_id: @tenant.id,
                                              divergence_type: ConciliacaoDeSaldo::TIPO_DIVERGENCIA)

      # O par registrado é o comparado, não sempre o disponível.
      assert_equal BigDecimal("700"), divergencia.expected_amount
      assert_equal BigDecimal("800"), divergencia.received_amount
      assert_equal "future", divergencia.metadata["base_da_comparacao"]
    end

    test "plataforma que responde sem número comparável não vira divergência" do
      com_saldo_interno(500)

      detalhe = rodar({ available: nil, future: nil, total: nil, source: "x" })[:detalhes].first

      assert_equal :sem_espelho, detalhe[:situacao]
      assert_equal :sem_valor_comparavel, detalhe[:motivo]
      assert_equal 0, DivergenceReport.where(tenant: @tenant).count
    end

    test "erro na leitura do saldo não derruba a conferência" do
      com_saldo_interno(500)

      explode = ->(start_date:, end_date:) { raise "API fora do ar" }

      resultado = com_metodo(Marketplace::Providers::MercadoLivreProvider, :account_balance, explode) do
        com_metodo(Marketplace::Providers::MercadoLivreProvider.singleton_class, :configured?, ->(_c) { true }) do
          ConciliacaoDeSaldo.new(tenant: @tenant).call
        end
      end

      assert_equal :sem_espelho, resultado[:detalhes].first[:situacao]
    end

    test "conta não conectada é reportada, não silenciada" do
      com_saldo_interno(500)

      resultado = ConciliacaoDeSaldo.new(tenant: @tenant).call

      assert_equal 1, resultado[:resumo][:sem_espelho]
    end
  end
end
