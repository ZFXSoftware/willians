require "test_helper"

module Financeiro
  class BaixaDeRecebimentosTest < ActiveSupport::TestCase
    setup do
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant, metadata: { "omie_conta_corrente_id" => "6455415244" })
      @repasse = criar_repasse(tenant: @tenant, conta: @conta, external_id: "PAY-1", bruto: 319.99)
    end

    # Monta recebível com nota fiscal e o aloca ao repasse.
    def com_nota(referencia, numero_nf, valor)
      pedido = criar_pedido(tenant: @tenant, conta: @conta, external_id: referencia)
      venda = criar_lancamento(tenant: @tenant, conta: @conta, pedido: pedido, valor: valor)
      nota = criar_nota(tenant: @tenant, pedido: pedido, numero: numero_nf, valor: valor)
      recebivel = criar_recebivel(tenant: @tenant, conta: @conta, pedido: pedido, nota: nota,
                                  bruto: valor, liquido: valor)
      alocar!(tenant: @tenant, lancamento: venda, recebivel: recebivel, repasse: @repasse, tipo: :payout)
      [venda, nota, recebivel]
    end

    def indice(codigo, numero, valor)
      TitulosFalsos.indice(TitulosFalsos.titulo(codigo: codigo, numero: numero, valor: valor))
    end

    test "simula quando a escrita no OMIE está bloqueada" do
      com_nota("P1", "000251372", 119.99)
      espiao = OmieEspiao.new

      resultado = com_env("OMIE_ALLOW_WRITES" => nil) do
        BaixaDeRecebimentos.new(payout_batch: @repasse, client: espiao,
                                titulos: indice(901, "251372", 119.99)).call
      end

      assert resultado[:resumo][:simulacao], "deveria rodar como simulação"
      assert_empty espiao.chamadas, "simulação não pode tocar no OMIE"
      assert_equal 1, resultado[:resumo][:baixaria]
    end

    test "baixa o título quando o valor confere" do
      com_nota("P1", "000251372", 119.99)
      espiao = OmieEspiao.new

      BaixaDeRecebimentos.new(payout_batch: @repasse, client: espiao, dry_run: false,
                              titulos: indice(901, "251372", 119.99)).call

      params = espiao.params_de("LancarRecebimento").first

      assert_equal 1, espiao.chamadas_de("LancarRecebimento").size
      assert_equal 901, params[:codigo_lancamento], "identifica o título pelo codigo_lancamento"
      assert_equal 119.99, params[:valor]
      assert_equal 6_455_415_244, params[:codigo_conta_corrente]
      assert_match %r{\A\d{2}/\d{2}/\d{4}\z}, params[:data], "data no formato do OMIE"
    end

    test "divergência bloqueia a baixa e abre um caso" do
      venda, nota, _ = com_nota("P2", "000251373", 200.00)
      espiao = OmieEspiao.new

      resultado = BaixaDeRecebimentos.new(payout_batch: @repasse, client: espiao, dry_run: false,
                                          titulos: indice(902, "251373", 180.00)).call

      assert_equal 1, resultado[:resumo][:divergente]
      assert_empty espiao.chamadas_de("LancarRecebimento"), "não pode baixar valor que não bate"

      divergencia = DivergenceReport.find_by(tenant_id: @tenant.id, financial_entry_id: venda.id)

      assert divergencia, "deveria abrir divergência"
      assert_equal BigDecimal("180.0"), divergencia.expected_amount
      assert_equal BigDecimal("200.0"), divergencia.received_amount
      assert_equal BigDecimal("20.0"), divergencia.difference_amount
      assert_equal nota.number, divergencia.metadata["nota_fiscal"]
    end

    test "deixa rastro da baixa para auditoria" do
      venda, _, _ = com_nota("P1", "000251372", 119.99)

      BaixaDeRecebimentos.new(payout_batch: @repasse, client: OmieEspiao.new, dry_run: false,
                              titulos: indice(901, "251372", 119.99)).call

      mapeamento = OmieFinancialMapping.find_by(financial_entry_id: venda.id)

      assert mapeamento&.synced?
      assert_equal "901", mapeamento.omie_financial_id
      assert_equal "PAY-1", mapeamento.metadata.dig("baixa", "payout")
    end

    test "conta os casos sem caminho em vez de ignorá-los" do
      _, nota, recebivel = com_nota("P1", "000251372", 119.99)

      recebivel.update!(invoice_id: nil)
      assert_equal 1, BaixaDeRecebimentos.new(payout_batch: @repasse, client: OmieEspiao.new,
                                              titulos: {}).call[:resumo][:sem_nota]

      recebivel.update!(invoice_id: nota.id)
      assert_equal 1, BaixaDeRecebimentos.new(payout_batch: @repasse, client: OmieEspiao.new,
                                              titulos: {}).call[:resumo][:titulo_nao_encontrado]
    end

    test "exige a conta corrente configurada" do
      com_nota("P1", "000251372", 119.99)
      @conta.update!(metadata: {})

      erro = assert_raises(BaixaDeRecebimentos::ConfiguracaoAusente) do
        com_env("OMIE_CONTA_CORRENTE_ID" => nil) do
          BaixaDeRecebimentos.new(payout_batch: @repasse, client: OmieEspiao.new, dry_run: false,
                                  titulos: indice(901, "251372", 119.99)).call
        end
      end

      assert_match(/conta_corrente/, erro.message)
    end

    test "zeros à esquerda não impedem o casamento da nota" do
      assert_equal Omie::Readers::OpenTitles.normalizar_numero("000251372"),
                   Omie::Readers::OpenTitles.normalizar_numero("251372")
    end
  end
end
