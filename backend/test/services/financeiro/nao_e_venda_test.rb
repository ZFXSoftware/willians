require "test_helper"

module Financeiro
  # Recebível que nasceu de linha que NÃO é venda fica marcado e não apagado — é o
  # registro do que aconteceu. Quem SOMA precisa respeitar a marca, e o lugar que
  # importa é o `PayoutEngine`: o `gross_amount` do repasse é um valor GRAVADO, e é
  # dele que a conciliação tira o lado interno.
  #
  # Foi aqui que eu quase me enganei de novo: pus o `reject` na conciliação e
  # escrevi um teste que passava sem ele, porque o bruto do repasse vinha da
  # fixture. Excluir na leitura não corrige a base; corrige quando o repasse é
  # recalculado.
  class NaoEVendaTest < ActiveSupport::TestCase
    def setup
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant)
      @pedido = criar_pedido(tenant: @tenant, conta: @conta, external_id: "PED-1")
    end

    def recebivel(externo:, valor:, marcado: false)
      unidade = criar_recebivel(tenant: @tenant, conta: @conta, pedido: @pedido,
                               bruto: valor, liquido: valor, external_id: externo,
                               previsto_para: Date.current - 1)

      if marcado
        unidade.update!(metadata: {
          ReceivableUnit::MARCA_NAO_E_VENDA => { "descricao" => "reserve_for_dispute" }
        })
      end

      unidade
    end

    test "o escopo vendas_reais deixa de fora o que foi marcado" do
      recebivel(externo: "MLREL-1-SALE", valor: 100)
      recebivel(externo: "MLREL-2-SALE", valor: 40, marcado: true)

      reais = ReceivableUnit.where(tenant_id: @tenant.id).vendas_reais

      assert_equal [ "MLREL-1-SALE" ], reais.pluck(:external_id)
    end

    test "nao_e_venda? responde pela marca" do
      assert_not recebivel(externo: "MLREL-1-SALE", valor: 100).nao_e_venda?
      assert recebivel(externo: "MLREL-2-SALE", valor: 40, marcado: true).nao_e_venda?
    end

    # O que realmente conserta a base: o bruto do repasse, recalculado, deixa de
    # somar a reserva de disputa que nunca foi venda.
    test "o bruto do repasse recalculado exclui o que não é venda" do
      recebivel(externo: "MLREL-1-SALE", valor: 100)
      recebivel(externo: "MLREL-2-SALE", valor: 40, marcado: true)

      saque = criar_lancamento(tenant: @tenant, conta: @conta, tipo: :settlement,
                               direcao: :debit, valor: 100, external_id: "MLREL-PAYOUT")

      PayoutEngine.new(
        tenant: @tenant, platform_account: @conta,
        payout_reference: "MLREL-PAYOUT", paid_at: Time.current,
        settlement_entry: saque
      ).call

      lote = PayoutBatch.where(tenant_id: @tenant.id).order(:id).last

      assert_not_nil lote, "o repasse não foi criado"

      assert_equal BigDecimal("100"), lote.gross_amount.to_d,
                   "a reserva de disputa marcada não pode entrar no bruto do repasse"
    end
  end
end
