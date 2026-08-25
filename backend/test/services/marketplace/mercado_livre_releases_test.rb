require "test_helper"

module Marketplace
  # O relatório de Liberações é o extrato do dinheiro do Mercado Pago. É a
  # única fonte do ML que traz ORDER_ID junto com o valor bruto — sem ele não
  # há como ligar o repasse à nota fiscal, e a baixa automática não acontece.
  class MercadoLivreReleasesTest < ActiveSupport::TestCase
    ML = Marketplace::MercadoLivre

    DE = Date.new(2026, 8, 1)

    ATE = Date.new(2026, 8, 7)

    # Colunas conferidas na documentação. Traz de propósito: uma venda com
    # deduções, um estorno, um saque e as linhas de resumo.
    CSV_RELATORIO = <<~CSV
      DATE,SOURCE_ID,EXTERNAL_REFERENCE,ORDER_ID,RECORD_TYPE,DESCRIPTION,GROSS_AMOUNT,MP_FEE_AMOUNT,SHIPPING_FEE_AMOUNT,TAXES_AMOUNT,NET_CREDIT_AMOUNT,NET_DEBIT_AMOUNT,PAYMENT_METHOD
      2026-08-01T10:00:00Z,,,,initial_available_balance,Saldo anterior,0,0,0,0,0,0,
      2026-08-02T10:00:00Z,PAY-111,,2000000111,release,Venda,150.00,-15.50,-8.00,-2.25,124.25,0,credit_card
      2026-08-03T10:00:00Z,PAY-222,,2000000222,release,Estorno,-40.00,4.10,0,0,0,35.90,credit_card
      2026-08-04T10:00:00Z,PAY-333,,,payout,Transferência bancária,0,0,0,0,0,100.00,
      2026-08-05T10:00:00Z,PAY-444,,2000000444,chargeback,Contestação,-30.00,0,0,0,0,30.00,
      2026-08-06T10:00:00Z,PAY-555,,2000000555,tipo_novo_do_ml,Algo que não conhecemos,-5.00,0,0,0,0,5.00,
      2026-08-07T10:00:00Z,,,,total,Valor líquido total,0,0,0,0,124.25,0,
    CSV

    def eventos(csv = CSV_RELATORIO)
      ML::ReleaseEvents.new(csv: csv).call
    end

    def por_id(csv = CSV_RELATORIO)
      eventos(csv).index_by { |e| e[:external_id] }
    end

    def capturando_log
      anterior = Rails.logger

      saida = StringIO.new

      Rails.logger = ActiveSupport::Logger.new(saida)

      yield

      saida.string
    ensure
      Rails.logger = anterior
    end

    # ----------------------------------------------------------- normalização

    test "a venda entra pelo bruto, vinculada ao pedido" do
      venda = por_id.fetch("MLREL-PAY-111-SALE")

      # Bruto, e não líquido: é assim que o título existe no OMIE, e é o que a
      # conciliação compara.
      assert_equal BigDecimal("150.00"), venda[:amount]
      assert_equal :sale, venda[:entry_type]
      assert_equal :credit, venda[:direction]
      assert_equal "2000000111", venda[:external_order_id], "o elo com a NF do Tiny"
    end

    test "cada dedução vira um lançamento discriminado" do
      lancamentos = por_id

      tarifa = lancamentos.fetch("MLREL-PAY-111-FEE")
      frete = lancamentos.fetch("MLREL-PAY-111-SHIP")
      imposto = lancamentos.fetch("MLREL-PAY-111-TAX")

      assert_equal [BigDecimal("15.50"), BigDecimal("8.00"), BigDecimal("2.25")],
                   [tarifa, frete, imposto].map { |e| e[:amount] }
      assert [tarifa, frete, imposto].all? { |e| e[:direction] == :debit }
      # O razão não tem tipo para imposto; o sufixo do identificador é o que
      # mantém a distinção legível.
      assert_equal :fee, imposto[:entry_type]
      # A taxa fica amarrada ao mesmo pedido da venda.
      assert_equal "2000000111", tarifa[:external_order_id]
    end

    test "bruto negativo é estorno, e taxa devolvida volta como crédito" do
      lancamentos = por_id

      estorno = lancamentos.fetch("MLREL-PAY-222-REFUND")

      assert_equal :refund, estorno[:entry_type]
      assert_equal :debit, estorno[:direction], "estorno tira dinheiro"
      assert_equal BigDecimal("40.00"), estorno[:amount], "guardamos o módulo"

      devolvida = lancamentos.fetch("MLREL-PAY-222-FEE")

      assert_equal :credit, devolvida[:direction], "tarifa devolvida é dinheiro voltando"
      assert_equal BigDecimal("4.10"), devolvida[:amount]
    end

    test "saque é liquidação, não despesa, e não tem pedido" do
      saque = por_id.fetch("MLREL-PAY-333-PAYOUT")

      assert_equal :settlement, saque[:entry_type]
      assert_equal BigDecimal("100.00"), saque[:amount]
      assert_nil saque[:external_order_id], "saque é da conta, não de um pedido"
    end

    test "linhas de resumo não viram lançamento" do
      ids = eventos.map { |e| e[:external_id] }

      assert ids.none? { |id| id.include?("BALANCE") || id.include?("TOTAL") },
             "saldo anterior e total são conferência, não movimentação"
    end

    test "contestação vira lançamento rastreável até o pedido" do
      contestacao = por_id.fetch("MLREL-PAY-444-CHARGEBACK")

      assert_equal :chargeback, contestacao[:entry_type]
      assert_equal :debit, contestacao[:direction]
      assert_equal BigDecimal("30.00"), contestacao[:amount]
      assert_equal "2000000444", contestacao[:external_order_id],
                   "sem o pedido não há como chegar na NF de origem"
    end

    test "tipo desconhecido é contado, não engolido" do
      leitor = ML::ReleaseEvents.new(csv: CSV_RELATORIO)
      leitor.call

      assert_equal({ "tipo_novo_do_ml" => 1 }, leitor.ignorados,
                   "o que não sabemos tratar precisa aparecer, não sumir")
    end

    # O relatório REAL do Mercado Pago, com o cabeçalho copiado do log da
    # produção: separado por ponto e vírgula. Com vírgula, o cabeçalho inteiro
    # virava uma coluna só e as 41 linhas produziam zero lançamentos.
    CSV_REAL = <<~CSV
      DATE;SOURCE_ID;DESCRIPTION;NET_CREDIT_AMOUNT;NET_DEBIT_AMOUNT;GROSS_AMOUNT;MP_FEE_AMOUNT;TAXES_AMOUNT;PAYMENT_METHOD;TRANSACTION_APPROVAL_DATE;BUSINESS_UNIT;SUB_UNIT;BALANCE_AMOUNT;PAYMENT_METHOD_TYPE;PURCHASE_ID
      2026-08-24T10:00:00Z;PAY-111;Venda;124,25;0;150,00;-15,50;-2,25;credit_card;2026-08-24T09:00:00Z;mercadolibre;sales;1000,00;credit_card;2000000111
    CSV

    test "reconhece o relatório separado por ponto e vírgula" do
      leitor = ML::ReleaseEvents.new(csv: CSV_REAL)

      leitor.call
    rescue ML::ReleaseEvents::LayoutDesconhecido
      # A recusa é assunto do teste seguinte; aqui só interessa que as colunas
      # foram separadas de verdade, e não lidas como um nome gigante.
      assert_includes leitor.diagnostico[:colunas], "GROSS_AMOUNT"
      assert_includes leitor.diagnostico[:colunas], "PURCHASE_ID"
      assert_equal 1, leitor.diagnostico[:linhas]
    end

    # Sem RECORD_TYPE toda linha cairia no ramo de venda: um saque viraria
    # receita. Dado financeiro errado é pior do que dado nenhum.
    test "relatório sem RECORD_TYPE recusa importar em vez de adivinhar" do
      leitor = ML::ReleaseEvents.new(csv: CSV_REAL)

      registro = capturando_log do
        erro = assert_raises(ML::ReleaseEvents::LayoutDesconhecido) { leitor.call }

        assert_includes erro.message, "RECORD_TYPE"
      end

      # O que sobra para montar o de-para depois.
      assert_includes registro, "mercadolibre | sales | Venda -> 1"
    end

    # O pior zero possível: o relatório veio cheio e o leitor não reconheceu
    # nada. Sem aviso, isso chega na tela como "0 lançamento(s)" — igualzinho
    # a uma conta que não vendeu.
    test "linhas sem nenhum lançamento produzido avisam quais colunas vieram" do
      estranho = <<~CSV
        DATA,ID_ORIGEM,PEDIDO,RECORD_TYPE,VALOR_BRUTO
        2026-08-02T10:00:00Z,PAY-111,2000000111,release,150.00
      CSV

      leitor = ML::ReleaseEvents.new(csv: estranho)

      registro = capturando_log { assert_empty leitor.call }

      assert_includes registro, "NENHUM lançamento produzido", "silêncio aqui esconde o problema"
      assert_includes registro, "DATA, ID_ORIGEM, PEDIDO, RECORD_TYPE, VALOR_BRUTO"
    end

    test "relatório legítimo e completo não gera aviso de leitura muda" do
      leitor = ML::ReleaseEvents.new(csv: CSV_RELATORIO)

      registro = capturando_log { leitor.call }

      assert_not_includes registro, "NENHUM lançamento",
                          "avisar quando está tudo certo ensina a ignorar o aviso"
    end

    # Vender e ter saldo declarado são coisas diferentes no relatório: o saldo
    # vem de linhas de RESUMO, à parte da movimentação. Quando a conta vende o
    # dia inteiro e a conferência de saldo diz que não veio nada, é isto — e
    # sem o log não havia como saber sem abrir o CSV na mão.
    test "movimentação sem linhas de resumo é registrada como saldos ausentes" do
      so_movimento = <<~CSV
        DATE,SOURCE_ID,ORDER_ID,RECORD_TYPE,GROSS_AMOUNT,MP_FEE_AMOUNT
        2026-08-02T10:00:00Z,PAY-111,2000000111,release,150.00,-15.50
      CSV

      leitor = ML::ReleaseEvents.new(csv: so_movimento)

      registro = capturando_log { assert_equal 2, leitor.call.size }

      assert_includes registro, "saldos AUSENTES"
      assert_includes registro, "release"
      assert_empty leitor.diagnostico[:saldos]
    end

    test "o diagnóstico conta todos os tipos vistos, não só os desconhecidos" do
      leitor = ML::ReleaseEvents.new(csv: CSV_RELATORIO)
      leitor.call

      tipos = leitor.diagnostico[:tipos]

      assert_equal 2, tipos["release"]
      assert_equal 1, tipos["payout"]
      assert_equal 1, tipos["tipo_novo_do_ml"]
      assert_equal %w[initial_available_balance total], leitor.diagnostico[:saldos].sort
    end

    test "external_id é estável entre execuções e único" do
      primeira = eventos.map { |e| e[:external_id] }

      assert_equal primeira.sort, eventos.map { |e| e[:external_id] }.sort
      assert_equal primeira.size, primeira.uniq.size
    end

    test "relatório vazio não quebra" do
      assert_empty eventos("")
      assert_empty eventos("DATE,SOURCE_ID,ORDER_ID,RECORD_TYPE,GROSS_AMOUNT\n")
    end

    test "valor ilegível não derruba a leitura inteira" do
      csv = "DATE,SOURCE_ID,ORDER_ID,RECORD_TYPE,GROSS_AMOUNT,MP_FEE_AMOUNT\n" \
            "2026-08-02T10:00:00Z,PAY-9,2000000999,release,abc,-1.00\n"

      lancamentos = eventos(csv)

      assert_equal 1, lancamentos.size, "só a taxa sobrevive; o bruto ilegível vira zero"
      assert_equal :fee, lancamentos.first[:entry_type]
    end

    # -------------------------------------------------------------- persistência

    test "as vendas do ML viram lançamentos e não duplicam na reingestão" do
      tenant = criar_tenant
      conta = criar_conta(tenant: tenant)
      fixos = eventos

      ingerir = lambda do
        Ingestors::MarketplaceIngestor.new(
          tenant: tenant, platform_account: conta, start_date: DE, end_date: ATE
        ).call
      end

      com_metodo(Providers::MercadoLivreProvider, :financial_events,
                 ->(start_date:, end_date:) { fixos }) do
        com_metodo(Providers::MercadoLivreProvider.singleton_class, :configured?, ->(_c) { true }) do
          primeiro = ingerir.call

          assert_equal fixos.size, primeiro[:created]

          persistidos = FinancialEntry.where(tenant: tenant).where("external_id LIKE 'MLREL-%'")

          assert_equal fixos.size, persistidos.count
          assert_operator persistidos.sales.count, :>, 0, "agora o ML traz venda de verdade"
          assert_operator persistidos.where.not(order_id: nil).count, :>, 0, "pedido vinculado"

          assert_equal 0, ingerir.call[:created]
        end
      end
    end
  end
end
