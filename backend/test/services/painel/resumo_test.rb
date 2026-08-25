require "test_helper"

module Painel
  # A lista de movimentações é a primeira coisa que o cliente lê no sistema.
  #
  # Ela vinha mostrando "Refund · MLREL-173004257859-REFUND": o tipo em inglês,
  # que é o nome que o programador deu, e o nosso identificador interno, que não
  # diz nada a ninguém. O que a pessoa reconhece é o número do PEDIDO — é por
  # ele que ela acha a venda no marketplace e a nota no Tiny.
  class ResumoTest < ActiveSupport::TestCase
    def setup
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant)
    end

    def primeira
      Resumo.new(tenant: @tenant).call[:ultimas_movimentacoes].first
    end

    test "a movimentação sai em pedaços, para a tela montar a frase" do
      pedido = criar_pedido(tenant: @tenant, conta: @conta, external_id: "2000000111")

      criar_lancamento(tenant: @tenant, conta: @conta, tipo: :sale, pedido: pedido)

      movimentacao = primeira

      assert_equal "sale", movimentacao[:tipo]
      assert_equal "2000000111", movimentacao[:pedido]
      assert_not_nil movimentacao[:referencia]
    end

    # Um repasse para o banco não é de nenhum pedido em particular. A tela
    # precisa saber disso para dizer "sem pedido associado" em vez de mentir.
    test "lançamento sem pedido devolve pedido nulo, e não um vazio disfarçado" do
      criar_lancamento(tenant: @tenant, conta: @conta, tipo: :settlement, direcao: :debit)

      assert_nil primeira[:pedido]
    end

    # O relatório de liberações do ML não traz o número do pedido — PURCHASE_ID
    # vem vazio em todas as linhas. Sobra o id do pagamento no Mercado Pago:
    # não é o pedido, mas é por ele que a pessoa acha a linha no extrato.
    test "sem pedido, o id do pagamento ainda identifica o lançamento" do
      lancamento = criar_lancamento(tenant: @tenant, conta: @conta, tipo: :sale)

      lancamento.update!(metadata: { "source_id" => "PAY-123" })

      assert_nil primeira[:pedido]
      assert_equal "PAY-123", primeira[:pagamento]
    end
  end
end
