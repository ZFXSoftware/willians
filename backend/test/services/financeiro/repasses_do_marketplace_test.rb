require "test_helper"

module Financeiro
  # A corrente inteira, com o formato REAL do relatório do Mercado Livre:
  #
  #   extrato -> lançamentos -> recebível -> LOTE DE REPASSE -> conciliação
  #
  # O elo que faltava era o penúltimo. O ConciliacaoEngine itera sobre
  # PayoutBatch, e PayoutBatch só nascia do PayoutEngine, que ninguém chamava.
  # Resultado: razão cheio e tela de conciliação vazia.
  #
  # O relatório real não traz o número do pedido (PURCHASE_ID vem vazio), então
  # tudo aqui se amarra pelo SOURCE_ID — o id do pagamento no Mercado Pago.
  class RepassesDoMarketplaceTest < ActiveSupport::TestCase
    def setup
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant, plataforma: "mercado_livre")
    end

    def lancamento(tipo:, direcao:, valor:, external_id:, pagamento: nil, ocorrido: 3.days.ago)
      FinancialEntry.create!(
        tenant: @tenant, platform_account: @conta,
        external_id: external_id, source: :mercado_livre,
        entry_type: tipo, direction: direcao, amount: valor,
        occurred_at: ocorrido, available_on: ocorrido.to_date,
        status: :settled, settled_at: ocorrido,
        metadata: pagamento ? { "source_id" => pagamento } : {}
      )
    end

    # Uma linha `payment` do relatório vira venda + deduções, todas com o mesmo
    # SOURCE_ID e nenhum pedido.
    def venda_com_taxa(pagamento: "PAY-1", bruto: 150, taxa: 15, ocorrido: 3.days.ago)
      lancamento(tipo: :sale, direcao: :credit, valor: bruto, ocorrido: ocorrido,
                 external_id: "MLREL-#{pagamento}-SALE", pagamento: pagamento)

      lancamento(tipo: :fee, direcao: :debit, valor: taxa, ocorrido: ocorrido,
                 external_id: "MLREL-#{pagamento}-FEE", pagamento: pagamento)
    end

    def repasse(pagamento: "PAY-9", valor: 135, ocorrido: 1.day.ago)
      lancamento(tipo: :settlement, direcao: :debit, valor: valor, ocorrido: ocorrido,
                 external_id: "MLREL-#{pagamento}-PAYOUT", pagamento: pagamento)
    end

    def fechar
      RepassesDoMarketplace.new(tenant: @tenant, platform_account: @conta).call
    end

    # ------------------------------------------------- o recebível sai certo

    # Sem agrupar pelo pagamento, a taxa ficava órfã (a âncora exigia pedido) e
    # o recebível saía pelo BRUTO — o "a receber" da tela apareceria maior do
    # que o dinheiro que de fato vai cair.
    test "a taxa da venda entra no recebível mesmo sem número de pedido" do
      venda_com_taxa(bruto: 150, taxa: 15)

      recebivel = ReceivableUnit.find_by(tenant: @tenant)

      assert_not_nil recebivel
      assert_equal BigDecimal("150"), recebivel.gross_amount
      assert_equal BigDecimal("15"), recebivel.fee_amount
      assert_equal BigDecimal("135"), recebivel.net_amount, "líquido é o que a loja recebe"
    end

    # A data real vem do extrato (available_on), e não do prazo estimado de 14
    # dias — que deixaria o recebível "vencendo" depois do repasse que já o
    # pagou, e o lote sairia vazio.
    test "o recebível é datado pelo extrato, não por prazo estimado" do
      venda_com_taxa(ocorrido: 3.days.ago)

      assert_equal 3.days.ago.to_date, ReceivableUnit.find_by(tenant: @tenant).expected_on
    end

    # ------------------------------------------------------------ o lote

    test "o repasse do extrato vira lote e liquida os recebíveis" do
      venda_com_taxa
      repasse

      resumo = fechar

      assert_equal 1, resumo[:repasses]
      assert_equal 1, resumo[:criados]

      lote = PayoutBatch.find_by(tenant: @tenant)

      assert_not_nil lote, "sem lote a conciliação não tem o que comparar"
      assert_equal "paid", lote.status
      assert_equal BigDecimal("150"), lote.gross_amount
      assert_equal BigDecimal("135"), lote.net_amount

      assert_equal "paid", ReceivableUnit.find_by(tenant: @tenant).status
    end

    # O lançamento de liquidação já veio no extrato. Se o engine criasse outro,
    # a mesma saída de dinheiro entraria duas vezes no razão.
    test "aproveita o lançamento do extrato em vez de criar um segundo" do
      venda_com_taxa
      liquidacao = repasse

      fechar

      assert_equal 1, FinancialEntry.where(tenant: @tenant, entry_type: :settlement).count
      assert_equal liquidacao.id, PayoutBatch.find_by(tenant: @tenant).financial_entry_id
    end

    test "rodar de novo não duplica o lote" do
      venda_com_taxa
      repasse

      fechar

      segunda = fechar

      assert_equal 0, segunda[:criados], "o repasse já fechado não pode virar outro lote"
      assert_equal 1, PayoutBatch.where(tenant: @tenant).count
    end

    # Um repasse cujo recebível ficou fora da janela saía com os totais
    # zerados: uma transferência real de R$ 50 aparecia como R$ 0,00 na tela de
    # conciliação. O dinheiro saiu — o valor do extrato é o piso.
    test "repasse sem recebível encontrado vale o que saiu no extrato" do
      repasse(valor: 50)

      fechar

      lote = PayoutBatch.find_by(tenant: @tenant)

      assert_equal BigDecimal("50"), lote.net_amount
      assert_equal BigDecimal("50"), lote.gross_amount, "R$ 0,00 num repasse real é mentira"
    end

    test "com recebível, quem manda é a soma dos recebíveis" do
      venda_com_taxa(bruto: 150, taxa: 15)
      repasse(valor: 135)

      fechar

      lote = PayoutBatch.find_by(tenant: @tenant)

      assert_equal BigDecimal("150"), lote.gross_amount, "o bruto é o da venda, não o do saque"
      assert_equal BigDecimal("135"), lote.net_amount
    end

    test "conta sem repasse nenhum não inventa lote" do
      venda_com_taxa

      assert_equal 0, fechar[:repasses]
      assert_equal 0, PayoutBatch.where(tenant: @tenant).count
    end

    # ------------------------------------------- a corrente até a conciliação

    test "com o lote, a conciliação passa a produzir registro" do
      venda_com_taxa
      repasse

      fechar

      Conciliacao::ConciliacaoEngine.new(
        tenant: @tenant, platform_account: @conta,
        start_date: Date.current - 30, end_date: Date.current,
        omie_client: Omie::FakeOmieClient.new
      ).call

      assert_operator ConciliacaoRegistro.where(tenant: @tenant).count, :>, 0,
                      "era esta a tela vazia: razão cheio e nenhum registro de conciliação"
    end

    # ------------------------------------------------ a chave contra o OMIE

    def conciliar(titulos)
      cliente = Object.new

      cliente.define_singleton_method(:request) do |_endpoint, _call, **_params|
        { "conta_receber_cadastro" => titulos, "total_de_paginas" => 1 }
      end

      Conciliacao::ConciliacaoEngine.new(
        tenant: @tenant, platform_account: @conta,
        start_date: Date.current - 30, end_date: Date.current,
        omie_client: cliente
      ).call

      ConciliacaoRegistro.where(tenant: @tenant).order(:id).last
    end

    # O índice do OMIE é montado por NÚMERO DE NOTA FISCAL. O nosso lado
    # mandava o external_id do recebível — MLREL-PAY-1-SALE, identificador
    # nosso, que não existe no OMIE. A comparação não tinha como casar, e todo
    # repasse saía como "sem título correspondente": é o traço na coluna
    # "Esperado (OMIE)".
    test "casa com o título do OMIE pelo número da nota fiscal" do
      venda_com_taxa(bruto: 150, taxa: 15)
      repasse

      pedido = criar_pedido(tenant: @tenant, conta: @conta, external_id: "2000000111")
      nota = criar_nota(tenant: @tenant, pedido: pedido, numero: "12345", valor: 150)

      ReceivableUnit.find_by(tenant: @tenant).update!(invoice: nota, order: pedido)

      fechar

      registro = conciliar([ { "numero_documento_fiscal" => "12345", "valor_documento" => "150.00" } ])

      assert_equal "matched", registro.status
      assert_equal BigDecimal("150"), registro.conciliation_metadata["valor_omie"].to_d
    end

    # A conciliação grava um registro por repasse A CADA execução — é o
    # histórico, e isso é de propósito. Mas a tela mostra ESTADO: sem o recorte,
    # rodar três vezes exibia o mesmo repasse três vezes e o resumo contava
    # tudo em triplicado.
    test "a listagem mostra só o estado atual de cada repasse" do
      venda_com_taxa
      repasse

      fechar

      3.times { conciliar([]) }

      lote = PayoutBatch.find_by(tenant: @tenant)

      assert_equal 3, ConciliacaoRegistro.where(payout_batch_id: lote.id).count,
                   "o histórico continua no banco"

      atuais = ConciliacaoRegistro.where(
        id: ConciliacaoRegistro.ids_dos_ultimos(@tenant.id)
      )

      assert_equal 1, atuais.count, "a tela mostra um repasse uma vez"
      assert_equal ConciliacaoRegistro.where(payout_batch_id: lote.id).maximum(:id), atuais.first.id
    end

    # Sem isto, "Título não encontrado" ficava aberta para sempre: o título
    # aparece no OMIE, o repasse passa a conferir, e a tela continua acusando
    # divergências que já não existem.
    test "divergência se fecha sozinha quando o repasse volta a bater" do
      venda_com_taxa(bruto: 150, taxa: 15)
      repasse

      pedido = criar_pedido(tenant: @tenant, conta: @conta, external_id: "2000000111")
      nota = criar_nota(tenant: @tenant, pedido: pedido, numero: "12345", valor: 150)

      fechar

      # Primeira rodada: o OMIE está vazio, e abre a divergência.
      conciliar([])

      assert_equal 1, DivergenceReport.where(tenant: @tenant, status: :open).count

      # O título chega ao OMIE e o recebível ganha a nota.
      ReceivableUnit.find_by(tenant: @tenant).update!(invoice: nota, order: pedido)

      conciliar([ { "numero_documento_fiscal" => "12345", "valor_documento" => "150.00" } ])

      assert_equal 0, DivergenceReport.where(tenant: @tenant, status: :open).count
      assert_equal 1, DivergenceReport.where(tenant: @tenant, status: :resolved).count
    end

    test "sem nota fiscal do nosso lado, o título do OMIE não é encontrado" do
      venda_com_taxa(bruto: 150, taxa: 15)
      repasse

      fechar

      registro = conciliar([ { "numero_documento_fiscal" => "12345", "valor_documento" => "150.00" } ])

      assert_nil registro.conciliation_metadata["valor_omie"],
                 "sem NF não há como saber QUAL título é o desta venda"
      assert_includes registro.observacao.to_s, "Sem título correspondente"
    end
  end
end
