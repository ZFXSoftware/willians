require "test_helper"

module Conciliacao
  # Melhoria de regra tem que alcançar repasse antigo.
  #
  # A janela do agendador é de 30 dias. O repasse #44 do cliente, pago em 25/07,
  # ficou fora dela e continuou pedindo revisão manual por uma regra que já existia —
  # e eu só descobri conferindo à mão, quase reportando como defeito do conserto o que
  # era defeito da janela.
  #
  # Então: a janela MAIS os que ainda não fecharam, de qualquer data. Os resolvidos
  # ficam de fora, porque reconferir o que já fecha custa leitura do OMIE e não muda
  # nada.
  class RepasseEmAbertoTest < ActiveSupport::TestCase
    def setup
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant)
    end

    # Um repasse com nota e título, pago na data pedida.
    def repasse_em(data, numero:, valor: 100)
      pedido = criar_pedido(tenant: @tenant, conta: @conta)

      pedido.update!(total_amount: valor)

      nota = criar_nota(tenant: @tenant, pedido: pedido, numero: numero, valor: valor)

      nota.update!(metadata: { "fiscal" => { "valor_produtos" => valor.to_s } })

      recebivel = criar_recebivel(
        tenant: @tenant, conta: @conta, pedido: pedido, nota: nota,
        bruto: valor, liquido: valor, external_id: "MLREL-#{numero}-SALE",
        previsto_para: data.to_date
      )

      lancamento = criar_lancamento(
        tenant: @tenant, conta: @conta, pedido: pedido, nota: nota, valor: valor,
        external_id: "MLREL-#{numero}-SALE"
      )

      repasse = criar_repasse(tenant: @tenant, conta: @conta, bruto: valor, liquido: valor,
                              pago_em: data, lancamento: lancamento)

      alocar!(tenant: @tenant, lancamento: lancamento, recebivel: recebivel,
              repasse: repasse, tipo: :payout)

      repasse
    end

    def conciliar(janela_de:, totais:)
      ConciliacaoEngine.new(
        tenant: @tenant, platform_account: @conta,
        start_date: janela_de, end_date: Date.current,
        omie_totals: totais
      ).call
    end

    def registro_de(repasse)
      ConciliacaoRegistro
        .where(tenant_id: @tenant.id, payout_batch_id: repasse.id)
        .order(:id)
        .last
    end

    test "repasse antigo em aberto volta a ser conferido fora da janela" do
      antigo = repasse_em(Time.current - 90.days, numero: "900", valor: 100)

      # Primeira volta: janela larga, e o título não está no OMIE — fica em aberto.
      conciliar(janela_de: Date.current - 120, totais: {})

      assert_equal "manual_review", registro_de(antigo).status

      # Agora a janela é curta e o repasse está MUITO fora dela. O título apareceu.
      conciliar(janela_de: Date.current - 30, totais: { "900" => BigDecimal("100") })

      assert_equal "matched", registro_de(antigo).status,
                   "repasse antigo em aberto tem que ser reconferido mesmo fora da janela"
    end

    # O outro lado: resolvido fica de fora, senão toda execução relê o OMIE para
    # reconfirmar o que já fecha.
    test "repasse já conciliado fora da janela não é reprocessado" do
      antigo = repasse_em(Time.current - 90.days, numero: "901", valor: 100)

      conciliar(janela_de: Date.current - 120, totais: { "901" => BigDecimal("100") })

      assert_equal "matched", registro_de(antigo).status

      antes = registro_de(antigo).id

      # Janela curta e um título DIFERENTE: se ele fosse reprocessado, a diferença
      # apareceria. Os números divergem de propósito — coincidir esconderia a falha.
      execucao = conciliar(janela_de: Date.current - 30, totais: { "901" => BigDecimal("77") })

      assert_equal antes, registro_de(antigo).id, "não deveria ter gerado registro novo"
      assert_equal 0, execucao.total_entries
    end
  end
end
