require "test_helper"

module Financeiro
  # O recebível é UM POR PAGAMENTO: o `external_id` dele é
  # `MLREL-<pagamento>-SALE`. Mas o valor dele era somado agrupando por PEDIDO, e
  # o Mercado Livre permite mais de um pagamento no mesmo pedido — parte no
  # cartão, parte no saldo.
  #
  # Medido na base do cliente: 62 pedidos assim, e em cada um os DOIS recebíveis
  # recebiam a soma das duas vendas. No pedido 2000018278874802 os pagamentos são
  # R$ 26,50 e R$ 140,00, a nota é R$ 166,50, e os dois recebíveis saíram com
  # R$ 166,50 — R$ 333,00 no repasse para uma venda de R$ 166,50. R$ 9.700,94 de
  # excesso no total, mais de 22% da diferença que a conciliação acusava.
  class RecebivelPorPagamentoTest < ActiveSupport::TestCase
    def setup
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant)
      @pedido = criar_pedido(tenant: @tenant, conta: @conta, external_id: "2000018278874802")
    end

    # `source_id` é o id do pagamento no Mercado Pago, e é o que venda e deduções
    # da MESMA linha do relatório compartilham.
    def lancar(pagamento:, tipo:, valor:, sufixo:)
      entry = criar_lancamento(
        tenant: @tenant, conta: @conta, pedido: @pedido, tipo: tipo, valor: valor,
        external_id: "MLREL-#{pagamento}-#{sufixo}"
      )

      entry.update!(metadata: { "source_id" => pagamento })

      Financeiro::ReceivableEngine.new(financial_entry: entry).call

      entry
    end

    test "cada pagamento do mesmo pedido gera um recebível com o valor dele" do
      lancar(pagamento: "177199470674", tipo: :sale, valor: 26.50, sufixo: "SALE")
      lancar(pagamento: "177199582314", tipo: :sale, valor: 140.00, sufixo: "SALE")

      recebiveis = ReceivableUnit.where(tenant_id: @tenant.id).order(:external_id).to_a

      assert_equal 2, recebiveis.size

      assert_equal [ BigDecimal("26.50"), BigDecimal("140.00") ],
                   recebiveis.map { |r| r.gross_amount.to_d }.sort,
                   "cada recebível vale o SEU pagamento, não a soma do pedido"

      assert_equal BigDecimal("166.50"), recebiveis.sum { |r| r.gross_amount.to_d },
                   "a soma tem de ser a venda, uma vez só"
    end

    # A taxa entra pelo pagamento dela, não pelo do vizinho: era isso que o
    # agrupamento por pedido garantia por acidente, e não pode ser perdido.
    test "a dedução vai para o recebível do próprio pagamento" do
      lancar(pagamento: "177199470674", tipo: :sale, valor: 26.50, sufixo: "SALE")
      lancar(pagamento: "177199582314", tipo: :sale, valor: 140.00, sufixo: "SALE")
      lancar(pagamento: "177199582314", tipo: :fee, valor: 13.48, sufixo: "FEE")

      grande = ReceivableUnit.find_by(tenant_id: @tenant.id,
                                      external_id: "MLREL-177199582314-SALE")

      pequeno = ReceivableUnit.find_by(tenant_id: @tenant.id,
                                       external_id: "MLREL-177199470674-SALE")

      assert_equal BigDecimal("13.48"), grande.fee_amount.to_d
      assert_equal BigDecimal("126.52"), grande.net_amount.to_d

      assert_equal BigDecimal("0"), pequeno.fee_amount.to_d,
                   "a taxa do outro pagamento não é dele"
    end

    # Recebível PAGO é congelado: o repasse foi liquidado sobre o valor antigo.
    # Sem isso, uma reimportação qualquer reescreveria valores em cima de baixa já
    # feita. Corrigir os que nasceram errados é ato deliberado, com parâmetro.
    test "recebível pago não é recalculado sem pedido explícito" do
      venda = lancar(pagamento: "1", tipo: :sale, valor: 26.50, sufixo: "SALE")

      ReceivableUnit.find_by(external_id: "MLREL-1-SALE").update!(status: :paid)

      venda.update!(amount: 99.00)

      Financeiro::ReceivableEngine.new(financial_entry: venda).call

      assert_equal BigDecimal("26.50"),
                   ReceivableUnit.find_by(external_id: "MLREL-1-SALE").gross_amount.to_d,
                   "pago não muda por conta própria"

      Financeiro::ReceivableEngine.new(financial_entry: venda, recalcular_pagos: true).call

      assert_equal BigDecimal("99.00"),
                   ReceivableUnit.find_by(external_id: "MLREL-1-SALE").gross_amount.to_d,
                   "com pedido explícito, corrige"
    end

    # Sem `source_id` o pedido continua sendo a chave: lançamento manual e
    # plataforma que não informa o pagamento não podem ficar sem recebível.
    test "sem pagamento informado, o pedido segue valendo como chave" do
      entry = criar_lancamento(tenant: @tenant, conta: @conta, pedido: @pedido,
                               tipo: :sale, valor: 90.00, external_id: "MANUAL-1")

      Financeiro::ReceivableEngine.new(financial_entry: entry).call

      recebivel = ReceivableUnit.find_by(tenant_id: @tenant.id, external_id: "MANUAL-1")

      assert_equal BigDecimal("90.00"), recebivel.gross_amount.to_d
    end
  end
end
