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
      assert_includes registro.observacao.to_s, "entre o valor das vendas e o das notas"
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

    # A medição não depende do relatório nem dos dados fiscais: ela compara o
    # bruto das vendas com o valor da nota, que estão no nosso banco desde
    # sempre. A primeira versão somava componentes e ficava cega até o reimporte.
    test "explica a diferença mesmo sem a linha do relatório e sem dados fiscais" do
      cenario(bruto: 184.65, valor_nota: 178.65)

      registro = conciliar(BigDecimal("178.65"))

      assert_includes registro.observacao.to_s, "entre o valor das vendas e o das notas"
      assert_includes registro.observacao.to_s, "sobra R$ 0,00".tr(",", ".")
    end

    # O caso que fazia a sobra ficar NEGATIVA em sete repasses: nota de PACOTE,
    # duas vendas, o cupom rateado por venda (1,56 + 2,44) e o desconto da nota
    # pelo total (4,00). Somar os dois contava o mesmo abatimento duas vezes.
    #
    # Duas vendas de um pacote são dois PEDIDOS diferentes compartilhando uma
    # nota. Na primeira versão deste teste eu pus as duas no mesmo pedido, e o
    # recebível — que é derivado do pedido — somou as duas vendas num só, com
    # bruto 200. O cenário estava errado, não o motor.
    test "nota de pacote com cupom rateado não conta o desconto em dobro" do
      nota = criar_nota(tenant: @tenant, pedido: @pedido, numero: "500", valor: 196.00)

      nota.update!(metadata: { "fiscal" => { "valor_desconto" => "4.00" } })

      # 100 + 100 de bruto contra 196 de nota: a diferença real é 4,00, e só.
      [ [ "MLREL-1-SALE", "1.56" ], [ "MLREL-2-SALE", "2.44" ] ].each do |ext, cupom|
        pedido = criar_pedido(tenant: @tenant, conta: @conta)

        unidade = criar_recebivel(
          tenant: @tenant, conta: @conta, pedido: pedido, nota: nota,
          bruto: 100.00, liquido: 100.00, external_id: ext, previsto_para: Date.current - 2
        )

        lancamento = criar_lancamento(
          tenant: @tenant, conta: @conta, pedido: pedido, nota: nota, valor: 100.00, external_id: ext
        )

        lancamento.update!(raw_payload: { "COUPON_AMOUNT" => cupom })

        unidade.update!(invoice_id: nota.id, gross_amount: 100.00)
      end

      ancora = FinancialEntry.find_by!(tenant_id: @tenant.id, external_id: "MLREL-1-SALE")

      repasse = criar_repasse(tenant: @tenant, conta: @conta, bruto: 200.00, liquido: 200.00,
                              pago_em: Time.current - 1.day, lancamento: ancora)

      ReceivableUnit.where(tenant_id: @tenant.id).find_each do |unidade|
        alocar!(tenant: @tenant,
                lancamento: FinancialEntry.find_by!(tenant_id: @tenant.id, external_id: unidade.external_id),
                recebivel: unidade, repasse: repasse, tipo: :payout)
      end

      registro = conciliar(BigDecimal("196.00"))

      assert_includes registro.observacao.to_s, "R$ 4,00".tr(",", ".")
      assert_includes registro.observacao.to_s, "sobra R$ 0,00".tr(",", ".")
      assert_not_includes registro.observacao.to_s, "MAIS que a diferença"
    end
  end
end
