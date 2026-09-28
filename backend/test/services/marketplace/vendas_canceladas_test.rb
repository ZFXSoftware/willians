require "test_helper"

module Marketplace
  # Pedido cancelado e estornado tem que deixar de contar como receita SEM ninguém pedir.
  #
  # Em 2026-09-28, 38 recebíveis de pedidos cancelados contavam como venda dentro de
  # repasses — R$ 6.204,72. Nada em `app/` escrevia a marca: só uma tarefa que eu rodei à
  # mão. O próximo cancelamento entraria como receita de novo.
  class VendasCanceladasTest < ActiveSupport::TestCase
    def setup
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant)
    end

    # `situacoes` é o que a API do Mercado Livre respondeu para os PAGAMENTOS do pedido.
    def venda(status_ml:, situacoes:, bruto: 150.00)
      pedido = criar_pedido(tenant: @tenant, conta: @conta)

      pedido.update!(metadata: pedido.metadata.to_h.merge(
        "status_ml" => status_ml,
        "situacoes_de_pagamento" => situacoes
      ))

      # MESMO `external_id` nos dois: criar o lançamento recalcula o recebível de igual
      # identificador. Com identificadores diferentes nasceriam DOIS recebíveis para o
      # mesmo pedido, e o teste mediria a duplicata em vez da marcação.
      externo = "MLREL-#{SecureRandom.hex(4)}-SALE"

      recebivel = criar_recebivel(
        tenant: @tenant, conta: @conta, pedido: pedido,
        bruto: bruto, liquido: bruto, external_id: externo
      )

      lancamento = criar_lancamento(tenant: @tenant, conta: @conta, pedido: pedido,
                                    valor: bruto, external_id: externo)

      repasse = criar_repasse(tenant: @tenant, conta: @conta, bruto: bruto, liquido: bruto,
                              pago_em: Time.current - 1.day, lancamento: lancamento)

      alocar!(tenant: @tenant, lancamento: lancamento, recebivel: recebivel,
              repasse: repasse, tipo: :payout)

      [ recebivel, repasse ]
    end

    def marcar
      VendasCanceladas.new(tenant: @tenant, platform_account: @conta).call
    end

    test "cancelado e estornado deixa de ser venda" do
      recebivel, = venda(status_ml: "cancelled", situacoes: [ "refunded" ])

      resultado = marcar

      assert_equal 1, resultado[:marcados]
      assert recebivel.reload.nao_e_venda?
      assert_equal "ingestao", recebivel.metadata.dig("nao_e_venda", "origem")
    end

    # A distinção que separou 38 cancelamentos de 4 vendas reais sem nota: pedido
    # cancelado cujo pagamento continua APROVADO é dinheiro que ficou com o cliente, e a
    # venda vale. Marcar essa esconderia receita de verdade.
    test "cancelado com pagamento aprovado continua sendo venda" do
      recebivel, = venda(status_ml: "cancelled", situacoes: [ "approved" ])

      assert_equal 0, marcar[:marcados]
      refute recebivel.reload.nao_e_venda?
    end

    test "pedido vivo não é tocado" do
      recebivel, = venda(status_ml: "paid", situacoes: [ "approved" ])

      assert_equal 0, marcar[:marcados]
      refute recebivel.reload.nao_e_venda?
    end

    # Sem o estado do pagamento não há o que afirmar. Pedido gravado antes desta captura
    # fica de fora em vez de ser marcado por meia evidência.
    test "sem estado do pagamento não marca" do
      recebivel, = venda(status_ml: "cancelled", situacoes: [])

      assert_equal 0, marcar[:marcados]
      refute recebivel.reload.nao_e_venda?
    end

    # Marcar sem recalcular não conserta nada: o bruto do repasse continuaria somando o
    # que a conciliação passou a ignorar. Foi o passo que eu fiz à mão três vezes hoje.
    test "o bruto do repasse é recalculado junto" do
      _, repasse = venda(status_ml: "cancelled", situacoes: [ "refunded" ], bruto: 150.00)

      assert_equal BigDecimal("150"), repasse.gross_amount.to_d

      resultado = marcar

      assert_equal 1, resultado[:repasses_recalculados]
      assert_equal BigDecimal("0"), repasse.reload.gross_amount.to_d
    end

    # Rodar duas vezes não pode contar duas.
    test "rodar de novo não marca o que já está marcado" do
      venda(status_ml: "cancelled", situacoes: [ "refunded" ])

      assert_equal 1, marcar[:marcados]
      assert_equal 0, marcar[:marcados]
    end

    # O repasse SEM venda nenhuma é saque de saldo, e o valor dele é o que saiu pelo
    # extrato. Zerar apagaria da tela dinheiro que saiu de verdade da conta do cliente.
    test "repasse que fica sem venda mantém o valor do extrato" do
      pedido = criar_pedido(tenant: @tenant, conta: @conta)

      pedido.update!(metadata: { "status_ml" => "cancelled", "situacoes_de_pagamento" => [ "refunded" ] })

      recebivel = criar_recebivel(tenant: @tenant, conta: @conta, pedido: pedido,
                                  bruto: 80, liquido: 80, external_id: "MLREL-x-SALE")

      # O lançamento de LIQUIDAÇÃO do repasse, que é o que diz quanto saiu.
      saida = criar_lancamento(tenant: @tenant, conta: @conta, tipo: :settlement,
                               direcao: :debit, valor: 3102.00)

      repasse = criar_repasse(tenant: @tenant, conta: @conta, bruto: 80, liquido: 80,
                              pago_em: Time.current - 1.day, lancamento: saida)

      alocar!(tenant: @tenant, lancamento: saida, recebivel: recebivel,
              repasse: repasse, tipo: :payout)

      marcar

      assert_equal BigDecimal("3102"), repasse.reload.gross_amount.to_d,
                   "sem venda, o valor do repasse é o que saiu pelo extrato"
    end
  end
end
