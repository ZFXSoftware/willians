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
      assert_includes registro.observacao.to_s, "desconto concedido ao comprador"
      assert_includes registro.observacao.to_s, "sobra R$ 0,00".tr(",", ".")
    end

    # O custo do parcelamento entra no GROSS_AMOUNT e a nota, corretamente, não o
    # documenta. Provado no pedido 2000017734810340.
    #
    # Ele sai da BASE de comparação, não da explicação: antes o bruto cru era
    # confrontado com a nota, a diferença nascia em quase todo repasse e nós a
    # explicávamos em prosa. Diferença que aparece sempre ensina a ignorar a
    # coluna. Aqui a lacuna entre bruto e nota É o parcelamento, então o repasse
    # tem de fechar em ZERO — não em "explicado".
    test "venda parcelada não produz diferença nenhuma" do
      cenario(
        bruto: 222.66, valor_nota: 194.65,
        relatorio: { "FINANCING_FEE_AMOUNT" => "-28.01", "COUPON_AMOUNT" => "0.00" }
      )

      registro = conciliar(BigDecimal("194.65"))

      assert_equal BigDecimal("0"), registro.diferenca.to_d,
                   "o parcelamento do comprador não é divergência"
      assert_equal "matched", registro.status
      assert_equal "28.01", registro.conciliation_metadata.dig("decomposicao", "parcelamento"),
                   "fora da diferença, mas visível para a tela"
    end

    # Sem a linha do relatório e sem os dados fiscais, a causa é DESCONHECIDA — e
    # o honesto é continuar pedindo revisão.
    #
    # Este teste já afirmou o contrário, quando o cálculo media `bruto − nota`:
    # ali a diferença se explicava sozinha, por tautologia. Voltar a somar
    # causas trouxe de volta a dependência do dado, e com ela a resposta certa
    # para quando o dado falta.
    test "sem a linha do relatório e sem dados fiscais, a diferença fica sem explicação" do
      cenario(bruto: 184.65, valor_nota: 178.65)

      registro = conciliar(BigDecimal("178.65"))

      assert_equal "divergent", registro.status
      assert_not_includes registro.observacao.to_s, "parcelamento e desconto"
    end

    # Diferença inteiramente atribuída não é divergência. Os 17 repasses do
    # cliente fechavam ao centavo e a tela mostrava 17 divergências vermelhas,
    # pedindo revisão manual de algo que já tinha resposta.
    test "diferença explicada por inteiro sai como explicado, não divergente" do
      cenario(bruto: 184.65, valor_nota: 178.65, fiscal: { "valor_desconto" => "6.00" })

      registro = conciliar(BigDecimal("178.65"))


      assert_equal "explicado", registro.status
      assert_equal BigDecimal("6.00"), registro.diferenca.to_d.abs

      # E não abre divergência para alguém investigar.
      assert_equal 0, DivergenceReport.where(tenant_id: @tenant.id, status: :open).count
    end

    # Sobrando dinheiro sem explicação, continua divergência — é o caso que
    # PRECISA de gente olhando, e confundi-lo com o explicado apagaria o sinal.
    test "sobra sem explicação continua divergente" do
      cenario(bruto: 300.00, valor_nota: 178.65, fiscal: { "valor_desconto" => "6.00" })

      registro = conciliar(BigDecimal("178.65"))

      assert_equal "divergent", registro.status
    end

    # O caso que passava da diferença em oito repasses: venda com parcelamento
    # cujo bruto NÃO excede a nota, porque a nota saiu já com o valor cheio que o
    # comprador pagou. O componente existe, a diferença não — e aplicar o
    # componente ali inventaria explicação.
    test "componente maior que a diferença não explica mais do que existe" do
      nota = criar_nota(tenant: @tenant, pedido: @pedido, numero: "500", valor: 200.00)

      nota.update!(metadata: { "fiscal" => { "valor_desconto" => "0.00" } })

      unidade = criar_recebivel(tenant: @tenant, conta: @conta, pedido: @pedido, nota: nota,
                                bruto: 202.00, liquido: 202.00, external_id: "MLREL-1-SALE",
                                previsto_para: Date.current - 2)

      lancamento = criar_lancamento(tenant: @tenant, conta: @conta, pedido: @pedido, nota: nota,
                                    valor: 202.00, external_id: "MLREL-1-SALE")

      # O relatório diz R$ 50 de parcelamento, e entre bruto e nota só há R$ 2.
      lancamento.update!(raw_payload: { "FINANCING_FEE_AMOUNT" => "-50.00", "COUPON_AMOUNT" => "0.00" })

      unidade.update!(invoice_id: nota.id)

      repasse = criar_repasse(tenant: @tenant, conta: @conta, bruto: 202.00, liquido: 202.00,
                              pago_em: Time.current - 1.day, lancamento: lancamento)

      alocar!(tenant: @tenant, lancamento: lancamento, recebivel: unidade,
              repasse: repasse, tipo: :payout)

      registro = conciliar(BigDecimal("200.00"))

      # O bruto do relatório CONTÉM o parcelamento, então a lacuna entre bruto e
      # nota nunca deveria ser menor que ele. Quando é — R$ 50 informados contra
      # R$ 2 de lacuna —, uma das duas fontes está errada. Antes o cálculo
      # absorvia isso até dar zero, o que escondia a contradição; agora ela
      # aparece como diferença negativa E a observação diz por quê.
      assert registro.diferenca.to_d.negative?, "a contradição entre as fontes tem de aparecer"
      assert_includes registro.observacao.to_s, "relatório e nota discordam"
    end

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
