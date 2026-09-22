require "test_helper"

module Conciliacao
  # A diferença entre o que o marketplace pagou e o que a nota documenta tem
  # três causas medidas: o custo do parcelamento que o Mercado Livre soma ao
  # bruto, o cupom, e o desconto na própria nota.
  #
  # Enquanto não eram descontadas, 45 de 184 vendas de um repasse apareciam como
  # divergência e o repasse ia para revisão manual por R$ 468 que nunca foram
  # dinheiro faltando.
  class AjustesConhecidosTest < ActiveSupport::TestCase
    def setup
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant)
      @pedido = criar_pedido(tenant: @tenant, conta: @conta)
    end

    # Monta o caso real: venda de 184,65 no marketplace, nota de 178,65 com
    # 6,00 de desconto, e o título no OMIE pelo valor da nota.
    def cenario(bruto:, valor_nota:, fiscal: {}, relatorio: {})
      nota = criar_nota(tenant: @tenant, pedido: @pedido, numero: "500", valor: valor_nota)

      nota.update!(metadata: { "fiscal" => fiscal }) if fiscal.present?

      recebivel = criar_recebivel(
        tenant: @tenant, conta: @conta, pedido: @pedido, nota: nota,
        bruto: bruto, liquido: bruto, external_id: "MLREL-1-SALE",
        previsto_para: Date.current - 2
      )

      # A nota vai no LANÇAMENTO também, e não só no recebível.
      #
      # O recebível é derivado do lançamento: criar o lançamento recalcula o
      # recebível de mesmo external_id e copia o `invoice_id` dele — que,
      # vazio, apagava o vínculo que o teste acabara de montar. É por isso que
      # `VinculoDeNotas` liga os dois lados, e não só o recebível.
      lancamento = criar_lancamento(
        tenant: @tenant, conta: @conta, pedido: @pedido, nota: nota, valor: bruto,
        external_id: "MLREL-1-SALE"
      )

      lancamento.update!(raw_payload: relatorio) if relatorio.present?

      repasse = criar_repasse(tenant: @tenant, conta: @conta, bruto: bruto, liquido: bruto,
                              pago_em: Time.current - 1.day, lancamento: lancamento)

      alocar!(tenant: @tenant, lancamento: lancamento, recebivel: recebivel,
              repasse: repasse, tipo: :payout)

      [ nota, repasse ]
    end

    # O motor reconhece o título por DUAS chaves — o número da nota e o
    # identificador do recebível — porque o OMIE guarda o que o criador mandou.
    # O índice real tem as duas; o teste também, senão exercita meio caminho.
    def conciliar(valor)
      totais = { "500" => valor, "MLREL-1-SALE" => valor }

      ConciliacaoEngine.new(
        tenant: @tenant, platform_account: @conta,
        start_date: Date.current - 10, end_date: Date.current,
        omie_totals: totais
      ).call

      ConciliacaoRegistro.where(tenant_id: @tenant.id).order(:id).last
    end

    test "o desconto da nota é descontado da diferença e ela sobra zerada" do
      cenario(bruto: 184.65, valor_nota: 178.65, fiscal: { "valor_desconto" => "6.00" })

      registro = conciliar(BigDecimal("178.65"))

      assert_equal BigDecimal("6.00"), registro.diferenca.to_d.abs
      assert_includes registro.observacao.to_s, "desconto na nota"
      assert_includes registro.observacao.to_s, "sobra R$ 0,00".tr(",", ".")
    end

    # O custo do parcelamento entra no GROSS_AMOUNT e a nota, corretamente, não
    # o documenta. Provado no pedido 2000017734810340.
    test "o parcelamento e o cupom do relatório também são descontados" do
      cenario(
        bruto: 222.66, valor_nota: 194.65,
        relatorio: { "FINANCING_FEE_AMOUNT" => "-28.01", "COUPON_AMOUNT" => "0.00" }
      )

      registro = conciliar(BigDecimal("194.65"))

      assert_includes registro.observacao.to_s, "parcelamento"
      assert_includes registro.observacao.to_s, "sobra R$ 0,00".tr(",", ".")
    end

    # Onde o dado ainda não foi reimportado, a diferença volta a aparecer como
    # real. É o desfecho honesto: melhor pedir revisão do que abater um valor
    # que ninguém mediu.
    test "sem o dado, a diferença continua sendo real" do
      cenario(bruto: 184.65, valor_nota: 178.65)

      registro = conciliar(BigDecimal("178.65"))

      assert_not_includes registro.observacao.to_s, "desconto na nota"
    end
  end
end
