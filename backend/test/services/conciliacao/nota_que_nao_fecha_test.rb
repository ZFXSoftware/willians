require "test_helper"

module Conciliacao
  # Nota cuja aritmética não fecha com ela mesma.
  #
  # A base leva o título do OMIE até a MERCADORIA, porque é a mercadoria que o bruto do
  # relatório mede. Fazer isso somando `desconto − frete` supõe que a nota obedece
  # `total = produtos + frete − desconto`. Em 39 notas do cliente ela não obedece, e a
  # ponte errava exatamente pelo que faltava — R$ 230,32, a maior causa que restava.
  #
  # `produtos − total` é a MESMA conta sempre que a nota fecha, e a certa quando não fecha.
  class NotaQueNaoFechaTest < ActiveSupport::TestCase
    def setup
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant)
    end

    def cenario(bruto:, valor_nota:, fiscal:, valor_pedido: nil)
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

      repasse = criar_repasse(tenant: @tenant, conta: @conta, bruto: bruto, liquido: bruto,
                              pago_em: Time.current - 1.day, lancamento: lancamento)

      alocar!(tenant: @tenant, lancamento: lancamento, recebivel: recebivel,
              repasse: repasse, tipo: :payout)
    end

    def conciliar(titulo)
      ConciliacaoEngine.new(
        tenant: @tenant, platform_account: @conta,
        start_date: Date.current - 10, end_date: Date.current,
        omie_totals: { "500" => titulo, "MLREL-1-SALE" => titulo }
      ).call

      ConciliacaoRegistro.where(tenant_id: @tenant.id).order(:id).last
    end

    # A primeira forma, 34 das 39: abatimento que o emissor deu e NÃO pôs no campo de
    # desconto. O total da nota é menor que os próprios produtos.
    test "abatimento não declarado na nota não abre diferença" do
      cenario(bruto: 149.65, valor_nota: 145.65,
              fiscal: { "valor_produtos" => "149.65" })

      registro = conciliar(BigDecimal("145.65"))

      assert_equal BigDecimal("0"), registro.diferenca.to_d
      assert_equal "matched", registro.status
    end

    # A segunda forma, 5 das 39: o juro do parcelamento embutido no TOTAL da nota e
    # ausente de produtos. O total é maior que os produtos, sem frete declarado.
    test "juro embutido no total da nota não abre diferença" do
      cenario(bruto: 219.64, valor_nota: 219.64,
              fiscal: { "valor_produtos" => "199.65" },
              valor_pedido: 199.65)

      registro = conciliar(BigDecimal("219.64"))

      assert_equal BigDecimal("0"), registro.diferenca.to_d
      assert_equal "matched", registro.status
    end

    # O que NÃO pode acontecer: o ajuste vir da nota não pode cancelar a discordância
    # entre o TÍTULO e a nota. Título duplicado tem que continuar aparecendo — é o caso
    # medido no repasse #35, R$ 169,65.
    test "título que discorda da nota continua aparecendo" do
      cenario(bruto: 149.65, valor_nota: 145.65,
              fiscal: { "valor_produtos" => "149.65" })

      # O dobro: é a assinatura da duplicata no OMIE.
      registro = conciliar(BigDecimal("291.30"))

      assert_in_delta 145.65, registro.diferenca.to_d.abs, 0.01
      refute_equal "matched", registro.status
    end

    # Sem `valor_produtos` não há mercadoria a que descer. Usar `−total` zeraria o
    # esperado e inventaria uma diferença do tamanho da nota.
    test "nota sem valor de produtos não zera o esperado" do
      cenario(bruto: 145.65, valor_nota: 145.65, fiscal: { "valor_frete" => "0" })

      registro = conciliar(BigDecimal("145.65"))

      assert_equal BigDecimal("0"), registro.diferenca.to_d
    end

    # E o caso de sempre continua valendo: onde a nota FECHA, as duas contas são a mesma.
    test "nota que fecha com desconto continua fechando" do
      cenario(bruto: 184.65, valor_nota: 178.65,
              fiscal: { "valor_produtos" => "184.65", "valor_desconto" => "6.00" })

      registro = conciliar(BigDecimal("178.65"))

      assert_equal BigDecimal("0"), registro.diferenca.to_d
      assert_equal "matched", registro.status
    end
  end
end
