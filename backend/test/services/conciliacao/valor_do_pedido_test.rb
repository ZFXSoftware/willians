require "test_helper"

module Conciliacao
  # O `GROSS_AMOUNT` do relatório é o que o COMPRADOR pagou: mercadoria mais o juro do
  # parcelamento que ele escolheu. Esse juro nunca foi receita do vendedor, então a nota
  # não o documenta — e a diferença entre os dois aparecia como divergência.
  #
  # Quem sabe quanto a venda valeu é o PEDIDO. `Order#total_amount` vem da API do
  # Mercado Livre e é escrito só pela ingestão dele; o Tiny cria pedido sem valor. Por
  # isso confrontá-lo com a nota confronta duas fontes independentes, e não a nota
  # consigo mesma.
  #
  # Entra como ÚLTIMO recurso por medição, não por gosto. Sobre as 3.718 notas do
  # cliente: hoje 3514 fecham com R$ 3.118,32 de módulos; com o pedido no último recurso
  # 3674 fecham com R$ 983,69; com o pedido PRIMEIRO só 3615 fecham e os módulos sobem
  # para R$ 11.211,94. Trocar a base por inteiro piora.
  class ValorDoPedidoTest < ActiveSupport::TestCase
    def setup
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant)
    end

    # `valor_pedido: nil` monta o caso em que a ingestão não trouxe o valor.
    def cenario(bruto:, valor_nota:, fiscal:, valor_pedido:, relatorio: {})
      pedido = criar_pedido(tenant: @tenant, conta: @conta)

      pedido.update!(total_amount: valor_pedido) if valor_pedido

      nota = criar_nota(tenant: @tenant, pedido: pedido, numero: "500", valor: valor_nota)

      nota.update!(metadata: { "fiscal" => fiscal })

      recebivel = criar_recebivel(
        tenant: @tenant, conta: @conta, pedido: pedido, nota: nota,
        bruto: bruto, liquido: bruto, external_id: "MLREL-1-SALE",
        previsto_para: Date.current - 2
      )

      lancamento = criar_lancamento(
        tenant: @tenant, conta: @conta, pedido: pedido, nota: nota, valor: bruto,
        external_id: "MLREL-1-SALE"
      )

      lancamento.update!(raw_payload: relatorio) if relatorio.present?

      repasse = criar_repasse(tenant: @tenant, conta: @conta, bruto: bruto, liquido: bruto,
                              pago_em: Time.current - 1.day, lancamento: lancamento)

      alocar!(tenant: @tenant, lancamento: lancamento, recebivel: recebivel,
              repasse: repasse, tipo: :payout)

      repasse
    end

    def conciliar(valor)
      ConciliacaoEngine.new(
        tenant: @tenant, platform_account: @conta,
        start_date: Date.current - 10, end_date: Date.current,
        omie_totals: { "500" => valor, "MLREL-1-SALE" => valor }
      ).call

      ConciliacaoRegistro.where(tenant_id: @tenant.id).order(:id).last
    end

    # O caso das 169 notas: bruto acima da mercadoria, sem frete e sem parcelamento no
    # relatório para explicar. O pedido diz que a venda valeu 139,65, e o resto do bruto
    # é juro do comprador.
    test "juro do comprador sai da base pelo valor do pedido" do
      cenario(bruto: 157.64, valor_nota: 139.65,
              fiscal: { "valor_produtos" => "139.65" },
              valor_pedido: 139.65)

      registro = conciliar(BigDecimal("139.65"))

      assert_equal BigDecimal("0"), registro.diferenca.to_d
      assert_equal "matched", registro.status
    end

    # Sem valor no pedido não há último recurso. Subtrair `bruto − 0` zeraria o lado
    # interno e inventaria uma diferença do tamanho do repasse — é o pior resultado
    # possível, e por isso tem teste.
    test "pedido sem valor não zera a base" do
      cenario(bruto: 157.64, valor_nota: 139.65,
              fiscal: { "valor_produtos" => "139.65" },
              valor_pedido: nil)

      registro = conciliar(BigDecimal("139.65"))

      # A sobra continua sem explicação — R$ 17,99, e não R$ 157,64.
      assert_in_delta 17.99, registro.diferenca.to_d.abs, 0.01
    end

    # A ORDEM importa, e é ela que a medição decidiu. Aqui a sobra é exatamente o frete,
    # e o valor do pedido é MENOR que a mercadoria — se o pedido viesse primeiro, ele
    # subtrairia 20,00 em vez dos 6,00 do frete e abriria diferença onde não há.
    test "hipótese nomeada ganha do valor do pedido" do
      cenario(bruto: 145.65, valor_nota: 145.65,
              fiscal: { "valor_produtos" => "139.65", "valor_frete" => "6.00" },
              valor_pedido: 125.65)

      registro = conciliar(BigDecimal("145.65"))

      # `frete` fecha: bruto − frete == produtos, e o título ajustado volta à mercadoria.
      assert_equal BigDecimal("0"), registro.diferenca.to_d
      assert_equal "matched", registro.status
    end

    # Quando o marketplace e a nota discordam sobre quanto a venda valeu, a diferença é
    # REAL e continua aparecendo. Medido em 64 das 3.718 notas do cliente. Esconder isso
    # seria o oposto do que a coluna de diferença existe para fazer.
    test "pedido que discorda da nota deixa a diferença à vista" do
      cenario(bruto: 200.00, valor_nota: 139.65,
              fiscal: { "valor_produtos" => "139.65" },
              valor_pedido: 180.00)

      registro = conciliar(BigDecimal("139.65"))

      # Interno 180,00 (o que o marketplace diz) contra 139,65 (o que a nota diz).
      assert_in_delta 40.35, registro.diferenca.to_d.abs, 0.01
      refute_equal "matched", registro.status
    end

    # O pedido valendo MAIS que o bruto não pode virar soma: subtrair um excedente
    # negativo aumentaria o lado interno e inventaria diferença para cima.
    test "pedido acima do bruto não infla a base" do
      cenario(bruto: 145.00, valor_nota: 139.65,
              fiscal: { "valor_produtos" => "139.65" },
              valor_pedido: 300.00)

      registro = conciliar(BigDecimal("139.65"))

      assert_in_delta 5.35, registro.diferenca.to_d.abs, 0.01
    end
  end
end
