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
      assert_includes registro.observacao.to_s, "parcelamento e desconto"
      assert_includes registro.observacao.to_s, "sobra R$ 0,00".tr(",", ".")
    end

    # O custo do parcelamento aparece no relatório e a nota não o documenta. Em
    # parte das vendas ele está SOMADO ao bruto (aqui: 222,66 = 194,65 + 28,01); em
    # outras é custo do vendedor, subtraído do bruto como a comissão — e lá a nota
    # vale o bruto inteiro e o parcelamento não explica lacuna nenhuma.
    #
    # Eu tentei tirá-lo da BASE de comparação para que venda parcelada nunca
    # gerasse diferença. Está errado: nas vendas do segundo tipo isso deixa o lado
    # interno MENOR que a nota, e produziu resíduo negativo em 19 de 35 repasses.
    # O relatório não distingue os dois casos — nas duas formas o líquido é
    # `bruto − comissão − frete − parcelamento` — e decidir pela nota seria
    # circular. Distinguir pede o PEDIDO, que sabe o que o comprador pagou.
    #
    # Enquanto isso, ele entra como CAUSA, limitado pela distância medida: onde
    # não há lacuna, o `min` impede que ele invente explicação.
    test "o parcelamento somado ao bruto é descontado como causa" do
      cenario(
        bruto: 222.66, valor_nota: 194.65,
        relatorio: { "FINANCING_FEE_AMOUNT" => "-28.01", "COUPON_AMOUNT" => "0.00" }
      )

      registro = conciliar(BigDecimal("194.65"))

      assert_includes registro.observacao.to_s, "parcelamento"
      assert_includes registro.observacao.to_s, "sobra R$ 0,00".tr(",", ".")
      assert_equal "28.01", registro.conciliation_metadata.dig("decomposicao", "parcelamento"),
                   "o valor fica visível para a tela mesmo entrando como causa"
    end

    # Recebível marcado como NÃO-VENDA sai das duas pontas: do bruto do repasse e
    # da conciliação. Se saísse de uma só, as duas voltariam a medir coisas
    # diferentes — que foi o meu erro ao tirar o parcelamento de um lado apenas.
    test "recebível marcado como não-venda não entra na comparação" do
      nota, repasse = cenario(bruto: 100.00, valor_nota: 100.00)

      intruso = criar_recebivel(tenant: @tenant, conta: @conta, pedido: @pedido,
                                bruto: 40.00, liquido: 40.00, external_id: "MLREL-RESERVA",
                                previsto_para: Date.current - 2)

      intruso.update!(metadata: {
        ReceivableUnit::MARCA_NAO_E_VENDA => { "descricao" => "reserve_for_dispute" }
      })

      lanc = criar_lancamento(tenant: @tenant, conta: @conta, pedido: @pedido,
                              valor: 40.00, external_id: "MLREL-RESERVA")

      alocar!(tenant: @tenant, lancamento: lanc, recebivel: intruso,
              repasse: repasse, tipo: :payout)

      registro = conciliar(BigDecimal("100.00"))

      assert_equal BigDecimal("0"), registro.diferenca.to_d,
                   "a reserva de disputa não é venda e não pode virar diferença"

      assert_equal nota.number, "500"
    end

    # Nota de pacote SEM título entrava pelo valor inteiro em cada repasse que
    # levou parte dela — dividida entre dois repasses, era contada duas vezes por
    # inteiro. O lado do OMIE já aplicava a fração; este componente não, e era daí
    # que vinha a maior parte dos resíduos negativos.
    #
    # O repasse precisa de ALGUMA nota com título, senão não há comparação e a
    # decomposição nem é gravada — por isso o cenário tem duas notas.
    test "nota de pacote sem título entra pela fração, não inteira" do
      com_titulo = criar_nota(tenant: @tenant, pedido: @pedido, numero: "500", valor: 100.00)

      venda_a = criar_recebivel(tenant: @tenant, conta: @conta, pedido: @pedido, nota: com_titulo,
                                bruto: 100.00, liquido: 100.00, external_id: "MLREL-A",
                                previsto_para: Date.current - 2)

      lancamento = criar_lancamento(tenant: @tenant, conta: @conta, pedido: @pedido,
                                    nota: com_titulo, valor: 100.00, external_id: "MLREL-A")

      # Nota de pacote: 200 para DUAS vendas de 100, e só uma entra neste repasse.
      pacote = criar_pedido(tenant: @tenant, conta: @conta, external_id: "PACOTE-1")

      sem_titulo = criar_nota(tenant: @tenant, pedido: pacote, numero: "700", valor: 200.00)

      venda_b = criar_recebivel(tenant: @tenant, conta: @conta, pedido: pacote, nota: sem_titulo,
                                bruto: 100.00, liquido: 100.00, external_id: "MLREL-B",
                                previsto_para: Date.current - 2)

      criar_recebivel(tenant: @tenant, conta: @conta, pedido: pacote, nota: sem_titulo,
                      bruto: 100.00, liquido: 100.00, external_id: "MLREL-C",
                      previsto_para: Date.current - 2)

      repasse = criar_repasse(tenant: @tenant, conta: @conta, bruto: 200.00, liquido: 200.00,
                              pago_em: Time.current - 1.day, lancamento: lancamento)

      [ venda_a, venda_b ].each do |unidade|
        alocar!(tenant: @tenant, lancamento: lancamento, recebivel: unidade,
                repasse: repasse, tipo: :payout)
      end

      ConciliacaoEngine.new(
        tenant: @tenant, platform_account: @conta,
        start_date: Date.current - 10, end_date: Date.current,
        omie_totals: { "500" => BigDecimal("100.00") }
      ).call

      registro = ConciliacaoRegistro.where(tenant_id: @tenant.id, payout_batch_id: repasse.id)
                                    .order(:id).last

      decomposicao = registro.conciliation_metadata.to_h["decomposicao"].to_h

      assert_equal "100.0", decomposicao["sem_titulo"],
                   "a nota de 200 dividida ao meio tem de entrar por 100 neste repasse"

      assert_operator decomposicao["residuo"].to_d, :>=, BigDecimal("-0.10"),
                      "contar a nota inteira faz a decomposição explicar mais do que existe"
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

      # O parcelamento informado (R$ 50) é maior que a lacuna entre bruto e nota
      # (R$ 2) — o que acontece quando ele é custo do vendedor e não valor somado
      # ao bruto. O `min` contra a distância medida explica os R$ 2 que existem, e
      # não os R$ 50 que o componente afirma.
      assert_includes registro.observacao.to_s, "R$ 2,00".tr(",", ".")
      assert_not_includes registro.observacao.to_s, "MAIS que a diferença"
      assert_equal "explicado", registro.status
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
