require "test_helper"

module Painel
  class SeriesTest < ActiveSupport::TestCase
    def setup
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant)
      @pedido = criar_pedido(tenant: @tenant, conta: @conta)
    end

    def venda(dia:, bruto: 100, liquido: 80, marcada: false)
      unidade = criar_recebivel(
        tenant: @tenant, conta: @conta, pedido: @pedido,
        bruto: bruto, liquido: liquido, previsto_para: dia.to_date,
        external_id: "MLREL-#{SecureRandom.hex(4)}-SALE"
      )

      if marcada
        unidade.update!(metadata: { ReceivableUnit::MARCA_NAO_E_VENDA => { "motivo" => "teste" } })
      end

      unidade
    end

    def saque(dia:, valor:)
      lancamento = criar_lancamento(tenant: @tenant, conta: @conta, tipo: :settlement,
                                    direcao: :debit, valor: valor, ocorrido_em: dia)

      criar_repasse(tenant: @tenant, conta: @conta, bruto: valor, liquido: valor,
                    pago_em: dia, lancamento: lancamento)
    end

    def series(dias: 90) = Series.new(tenant: @tenant, dias: dias).call

    test "soma valor e quantidade de vendas por dia" do
      venda(dia: 3.days.ago, bruto: 100)
      venda(dia: 3.days.ago, bruto: 150)
      venda(dia: 1.day.ago, bruto: 200)

      dias = series[:por_dia].index_by { |l| l[:dia] }

      assert_equal 2, dias[3.days.ago.to_date][:vendas_quantidade]
      assert_equal "250.0", dias[3.days.ago.to_date][:vendas_valor]
      assert_equal 1, dias[1.day.ago.to_date][:vendas_quantidade]
    end

    # Sem os dias vazios a linha "pula" o fim de semana, encurta o eixo e faz a série
    # parecer mais densa do que é.
    test "dia sem movimento aparece com zero" do
      venda(dia: 2.days.ago)

      ontem = series[:por_dia].find { |l| l[:dia] == 1.day.ago.to_date }

      assert_equal 0, ontem[:vendas_quantidade]
      assert_equal "0.0", ontem[:vendas_valor]
    end

    # O gráfico e a conciliação têm que contar a mesma coisa: recebível marcado como
    # não-venda (pedido cancelado, depósito) não é receita em nenhuma das duas.
    test "recebível marcado como não-venda fica fora" do
      venda(dia: 2.days.ago, bruto: 100)
      venda(dia: 2.days.ago, bruto: 999, marcada: true)

      dia = series[:por_dia].find { |l| l[:dia] == 2.days.ago.to_date }

      assert_equal 1, dia[:vendas_quantidade]
      assert_equal "100.0", dia[:vendas_valor]
    end

    # O saque é o que SAIU pelo lançamento de liquidação, e não o bruto do lote — que é o
    # valor das vendas da janela e costuma ser bem diferente.
    test "saque do dia vem do lançamento de liquidação" do
      saque(dia: 2.days.ago, valor: 5100)

      dia = series[:por_dia].find { |l| l[:dia] == 2.days.ago.to_date }

      assert_equal "5100.0", dia[:saques]
    end

    test "a janela é respeitada" do
      venda(dia: 200.days.ago, bruto: 999)
      venda(dia: 2.days.ago, bruto: 100)

      resultado = series(dias: 30)

      assert_equal 31, resultado[:por_dia].size
      assert_equal BigDecimal("100"), resultado[:por_dia].sum(BigDecimal("0")) { |l| l[:vendas_valor].to_d }
    end

    # Rosca com mais de seis fatias tem fatias que encostam, e a comparação vira
    # adivinhação. O resto vira "Outros", que continua somando certo.
    test "dobra os canais além do teto em Outros" do
      8.times do |i|
        nota = criar_nota(tenant: @tenant, pedido: @pedido, numero: "90#{i}", valor: (8 - i) * 100)

        nota.update!(operation_type: :sale, issued_at: 2.days.ago,
                     metadata: { "intermediador" => { "nome" => "Canal #{i}" } })
      end

      canais = series[:por_canal]

      assert_equal Series::TETO_DE_FATIAS, canais.size
      # Sem mapeamento vale o nome cru: "Canal 0" é a maior, e não um balde mudo.
      assert_equal "Canal 0", canais.first[:rotulo]
      assert_equal "Outros (3)", canais.last[:rotulo]
      # 300 + 200 + 100: o resto continua somando certo.
      assert_equal "600.0", canais.last[:receita]
    end

    # `líquido + comissão + frete + parcelamento` tem que dar o bruto — é o que uma rosca
    # sabe mostrar, e se não fechar ela mente.
    test "a composição do bruto fecha" do
      venda(dia: 2.days.ago, bruto: 1000)

      { "-FEE" => 150, "-SHIP" => 80, "-FIN" => 20 }.each do |sufixo, valor|
        criar_lancamento(tenant: @tenant, conta: @conta, tipo: :fee, direcao: :debit,
                         valor: valor, ocorrido_em: 2.days.ago,
                         external_id: "MLREL-#{SecureRandom.hex(4)}#{sufixo}")
      end

      partes = series[:composicao].to_h { |p| [ p[:parte], p[:valor] ] }

      assert_equal BigDecimal("150"), partes["comissao"]
      assert_equal BigDecimal("80"), partes["frete"]
      assert_equal BigDecimal("20"), partes["parcelamento"]
      assert_equal BigDecimal("750"), partes["liquido"]
      assert_equal BigDecimal("1000"), partes.values.sum
    end

    # Fatia negativa não existe numa rosca. Acontece quando a janela pega a taxa de uma
    # venda liberada antes dela.
    test "dedução maior que o bruto não gera fatia negativa" do
      venda(dia: 2.days.ago, bruto: 10)

      criar_lancamento(tenant: @tenant, conta: @conta, tipo: :fee, direcao: :debit,
                       valor: 500, ocorrido_em: 2.days.ago, external_id: "MLREL-x-FEE")

      liquido = series[:composicao].find { |p| p[:parte] == "liquido" }

      assert_equal BigDecimal("0"), liquido[:valor]
    end

    test "sem bruto no período a composição vem vazia" do
      assert_empty series[:composicao]
    end
  end
end
