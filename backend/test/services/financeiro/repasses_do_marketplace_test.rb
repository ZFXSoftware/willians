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

    # O histórico registra MUDANÇA, não passagem de tempo.
    #
    # O agendador roda a cada cinco minutos, e gravar uma linha por repasse por
    # volta fazia um único repasse do cliente acumular 2213 registros idênticos
    # — ~4000 linhas por dia para reescrever o mesmo estado. Execução que não
    # muda nada carimba a data no registro que já existe.
    test "a listagem mostra só o estado atual de cada repasse" do
      venda_com_taxa
      repasse

      fechar

      3.times { conciliar([]) }

      lote = PayoutBatch.find_by(tenant: @tenant)

      assert_equal 1, ConciliacaoRegistro.where(payout_batch_id: lote.id).count,
                   "três execuções sem novidade não são três fatos"

      atuais = ConciliacaoRegistro.where(
        id: ConciliacaoRegistro.ids_dos_ultimos(@tenant.id)
      )

      assert_equal 1, atuais.count, "a tela mostra um repasse uma vez"
      assert_equal ConciliacaoRegistro.where(payout_batch_id: lote.id).maximum(:id), atuais.first.id
    end

    # A outra metade da regra: quando o desfecho MUDA, isso é fato novo e
    # merece linha nova. Sem este teste, "não gravar nada" passaria como
    # otimização e o histórico deixaria de existir.
    test "mudança de desfecho grava registro novo" do
      venda_com_taxa(bruto: 150, taxa: 15)
      repasse

      pedido = criar_pedido(tenant: @tenant, conta: @conta, external_id: "2000000111")
      nota = criar_nota(tenant: @tenant, pedido: pedido, numero: "12345", valor: 150)

      fechar

      ReceivableUnit.find_by(tenant: @tenant).update!(invoice: nota, order: pedido)

      conciliar([])

      lote = PayoutBatch.find_by(tenant: @tenant)

      assert_equal 1, ConciliacaoRegistro.where(payout_batch_id: lote.id).count

      # O título aparece no OMIE: o repasse passa a conferir.
      conciliar([ { "numero_documento_fiscal" => "12345", "valor_documento" => "150.00" } ])

      assert_equal 2, ConciliacaoRegistro.where(payout_batch_id: lote.id).count,
                   "passar a conferir é mudança, e mudança é histórico"
      assert_equal "matched", ConciliacaoRegistro.where(payout_batch_id: lote.id).order(:id).last.status
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
      # Repasse em que NENHUMA venda tem nota cai no caminho de reserva, que
      # casa pela referência do recebível — e a frase é sobre título ausente,
      # não sobre nota faltando.
      assert_includes registro.observacao.to_s, "Nenhuma"
    end

    # Um repasse junta uma centena de vendas. Somar os títulos de três delas e
    # comparar com o repasse inteiro produz uma diferença enorme que não é
    # divergência nenhuma — é a ausência das outras noventa e sete. Quem lesse
    # isso concluiria que falta dinheiro.
    test "cobertura parcial não vira comparação" do
      venda_com_taxa(pagamento: "PAY-A", bruto: 100, taxa: 10)
      venda_com_taxa(pagamento: "PAY-B", bruto: 200, taxa: 20)
      repasse

      pedido = criar_pedido(tenant: @tenant, conta: @conta, external_id: "PED-A")
      nota = criar_nota(tenant: @tenant, pedido: pedido, numero: "111", valor: 100)

      # Só UM dos dois recebíveis tem nota fiscal.
      ReceivableUnit.where(tenant: @tenant).first.update!(invoice: nota, order: pedido)

      fechar

      registro = conciliar([ { "numero_documento_fiscal" => "111", "valor_documento" => "100.00" } ])

      # A regra mudou, e a razão é medida: duas vendas sem NF entre 268
      # travavam um repasse inteiro em "sem comparação", e as três buscas que
      # fizemos dizem que a nota delas não existe em lugar nenhum. Esperar por
      # ela é esperar para sempre.
      #
      # Comparar mesmo assim é honesto DESDE QUE se diga quanto da diferença é
      # falta de nota — senão volta a ser a divergência inventada que esta
      # regra existia para impedir.
      assert_equal "100.0", registro.conciliation_metadata["valor_omie"].to_s

      assert_includes registro.observacao.to_s, "sem nota fiscal"
      assert_includes registro.observacao.to_s, "200.00",
                      "sem o valor sem nota, a diferença parece rombo"
      assert_includes registro.observacao.to_s, "diferença real",
                      "a subtração é o ponto: deixá-la para o leitor é deixar o número no ar"
    end

    # O pacote do Mercado Livre: o comprador leva dois itens, o ML cria duas
    # vendas, e o Tiny emite UMA nota fiscal para o pacote.
    #
    # Contando recebíveis, o repasse tinha 2 vendas e 1 referência, `1 == 2`
    # nunca era verdade, e ele ficava em "comparação incompleta" para sempre —
    # por estar correto. O denominador tem que ser a NOTA.
    test "duas vendas do mesmo pacote compartilham uma nota e fecham a cobertura" do
      venda_com_taxa(pagamento: "PAY-A", bruto: 100, taxa: 10)
      venda_com_taxa(pagamento: "PAY-B", bruto: 200, taxa: 20)
      repasse

      pacote = criar_pedido(tenant: @tenant, conta: @conta, external_id: "PACK-1")
      nota = criar_nota(tenant: @tenant, pedido: pacote, numero: "111", valor: 300)

      ReceivableUnit.where(tenant: @tenant).find_each do |unidade|
        unidade.update!(invoice: nota, order: pacote)
      end

      fechar

      registro = conciliar([ { "numero_documento_fiscal" => "111", "valor_documento" => "300.00" } ])

      assert_equal "300.0", registro.conciliation_metadata["valor_omie"].to_s,
                   "uma nota para duas vendas é cobertura completa, não incompleta"
      assert_equal "matched", registro.status
    end

    # Nota de pacote cujas vendas caíram em repasses diferentes.
    #
    # Comparar a nota INTEIRA contra o repasse que pagou metade inventaria
    # diferença — mas recusar deixava o repasse travado sem saída. Dá para
    # saber a parte: cada venda tem o valor dela no extrato, então a fatia da
    # nota é a razão entre o que este repasse levou e o pacote inteiro.
    #
    # É rateio, não medição — a nota não diz quanto vale cada item. O erro é da
    # ordem do frete, e a alternativa era não comparar nada.
    test "nota de pacote partida entre repasses entra pela fração que coube" do
      venda_com_taxa(pagamento: "PAY-A", bruto: 100, taxa: 10)
      venda_com_taxa(pagamento: "PAY-B", bruto: 200, taxa: 20, ocorrido: 1.hour.ago)
      repasse

      pacote = criar_pedido(tenant: @tenant, conta: @conta, external_id: "PACK-1")
      nota = criar_nota(tenant: @tenant, pedido: pacote, numero: "111", valor: 300)

      ReceivableUnit.where(tenant: @tenant).find_each { |u| u.update!(invoice: nota, order: pacote) }

      fechar

      # A segunda venda fica FORA do lote.
      fora = ReceivableUnit.where(tenant: @tenant).order(:id).last

      FinancialEntryAllocation.where(receivable_unit_id: fora.id, allocation_type: "payout").delete_all

      registro = conciliar([ { "numero_documento_fiscal" => "111", "valor_documento" => "300.00" } ])

      # O repasse levou R$ 100 de um pacote de R$ 300: um terço da nota.
      assert_equal "100.0", registro.conciliation_metadata["valor_omie"].to_s,
                   "a fração é pelo VALOR das vendas, não pela contagem"
    end

    # A regra acima manda esperar pelas notas que faltam. Mas nota emitida sem
    # valor o OMIE recusa, e esperar por ela é esperar para sempre: o repasse
    # ficava em "comparação incompleta" sem prazo e sem explicação.
    #
    # Aqui a comparação acontece, e a diferença que aparece é real — é o
    # dinheiro que entrou sem documento fiscal correspondente.
    test "nota recusada por não ter valor não trava o repasse para sempre" do
      venda_com_taxa(pagamento: "PAY-A", bruto: 100, taxa: 10)
      venda_com_taxa(pagamento: "PAY-B", bruto: 200, taxa: 20)
      repasse

      pedido_a = criar_pedido(tenant: @tenant, conta: @conta, external_id: "PED-A")
      nota_a = criar_nota(tenant: @tenant, pedido: pedido_a, numero: "111", valor: 100)

      pedido_b = criar_pedido(tenant: @tenant, conta: @conta, external_id: "PED-B")
      nota_b = criar_nota(tenant: @tenant, pedido: pedido_b, numero: "222", valor: 0)

      nota_b.recusar_envio!(motivo: :sem_valor, mensagem: "Nota 222 está sem valor")

      unidades = ReceivableUnit.where(tenant: @tenant).order(:id).to_a

      unidades[0].update!(invoice: nota_a, order: pedido_a)
      unidades[1].update!(invoice: nota_b, order: pedido_b)

      fechar

      registro = conciliar([ { "numero_documento_fiscal" => "111", "valor_documento" => "100.00" } ])

      assert_equal "100.0", registro.conciliation_metadata["valor_omie"].to_s,
                   "compara com o que existe, em vez de esperar pelo que nunca vem"
      assert_includes registro.observacao.to_s, "sem valor"
      assert_includes registro.observacao.to_s, "222", "diz QUAL nota corrigir no Tiny"
    end

    # Nota que ainda não virou título no OMIE também não trava mais.
    #
    # A regra antiga esperava por ela, e isso parecia razoável — o título vai
    # chegar. Mas travava um repasse de 256 notas por UMA sem título, e a
    # diferença que apareceria seria exatamente o valor dela. Esperar em
    # silêncio por um envio que a própria tela dispara não é proteção.
    #
    # Compara e decompõe: quem lê vê quanto da diferença é título faltando e
    # quanto é diferença de verdade.
    test "nota pendente de envio é comparada, com o valor dela nomeado" do
      venda_com_taxa(pagamento: "PAY-A", bruto: 100, taxa: 10)
      venda_com_taxa(pagamento: "PAY-B", bruto: 200, taxa: 20)
      repasse

      pedido_a = criar_pedido(tenant: @tenant, conta: @conta, external_id: "PED-A")
      nota_a = criar_nota(tenant: @tenant, pedido: pedido_a, numero: "111", valor: 100)

      pedido_b = criar_pedido(tenant: @tenant, conta: @conta, external_id: "PED-B")
      nota_b = criar_nota(tenant: @tenant, pedido: pedido_b, numero: "222", valor: 200)

      unidades = ReceivableUnit.where(tenant: @tenant).order(:id).to_a

      unidades[0].update!(invoice: nota_a, order: pedido_a)
      unidades[1].update!(invoice: nota_b, order: pedido_b)

      fechar

      registro = conciliar([ { "numero_documento_fiscal" => "111", "valor_documento" => "100.00" } ])

      assert_equal "100.0", registro.conciliation_metadata["valor_omie"].to_s

      assert_includes registro.observacao.to_s, "sem título no OMIE"
      assert_includes registro.observacao.to_s, "200.00",
                      "o valor do título que falta é o que explica a diferença"
    end
  end
end
