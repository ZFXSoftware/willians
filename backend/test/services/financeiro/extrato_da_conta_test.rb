require "test_helper"

module Financeiro
  # "Na conta virtual Disponível −R$ 24.946,11, como assim?"
  #
  # Saldo negativo numa conta real é impossível, e a tela mostrava só o número. Para
  # descobrir de onde vinha eu escrevi script atrás de script, e a resposta era uma linha
  # de extrato. Este teste garante que a tela responde sozinha.
  class ExtratoDaContaTest < ActiveSupport::TestCase
    def setup
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant)
    end

    # Uma LINHA do relatório: `source` identifica a linha, e o saldo do marketplace vem
    # dela. Uma linha pode virar vários lançamentos nossos.
    def linha(source:, saldo:, quando:, descricao: "payment", partes:)
      partes.each_with_index.map do |(tipo, direcao, valor), indice|
        lancamento = criar_lancamento(
          tenant: @tenant, conta: @conta, tipo: tipo, direcao: direcao, valor: valor,
          external_id: "MLREL-#{source}-#{indice}", ocorrido_em: quando
        )

        lancamento.update!(raw_payload: {
          "DESCRIPTION" => descricao,
          "SOURCE_ID" => source,
          "DATE" => quando.iso8601,
          "BALANCE_AMOUNT" => saldo.to_s
        })

        lancamento
      end
    end

    def extrato(**opcoes)
      ExtratoDaConta.new(tenant: @tenant, platform_account: @conta, **opcoes).call
    end

    # A linha do relatório vira vários lançamentos — a venda pelo bruto e uma dedução por
    # taxa — e todos carregam o MESMO saldo do marketplace. Comparar lançamento a
    # lançamento acusaria divergência em cada taxa, o que é falso.
    test "uma linha do relatório é uma linha do extrato, com todos os lançamentos dela" do
      linha(source: "111", saldo: 80, quando: 3.days.ago,
            partes: [ [ :sale, :credit, 100 ], [ :fee, :debit, 20 ] ])

      resultado = extrato

      assert_equal 1, resultado[:total_de_linhas]

      primeira = resultado[:linhas].first

      assert_equal 2, primeira[:lancamentos]
      assert_equal BigDecimal("80"), primeira[:valor]
      assert_equal BigDecimal("80"), primeira[:saldo_nosso]
      assert_equal BigDecimal("80"), primeira[:saldo_deles]
      assert_equal BigDecimal("0"), primeira[:distancia]
    end

    # O que a tela existe para fazer: apontar O MOVIMENTO em que os dois saldos se
    # separaram. Depois dele, todos divergem — o erro é cumulativo —, então reportar a
    # última linha ou todas esconderia a única que responde a pergunta.
    test "aponta a primeira linha em que o nosso saldo se separa do deles" do
      linha(source: "111", saldo: 100, quando: 5.days.ago,
            partes: [ [ :sale, :credit, 100 ] ])

      # Aqui o marketplace diz 250 (creditou 150) e nós só registramos 50.
      linha(source: "222", saldo: 250, quando: 4.days.ago,
            partes: [ [ :sale, :credit, 50 ] ])

      linha(source: "333", saldo: 300, quando: 3.days.ago,
            partes: [ [ :sale, :credit, 50 ] ])

      divergencia = extrato[:primeira_divergencia]

      assert_equal "222", divergencia[:referencia]
      assert_equal BigDecimal("-100"), divergencia[:salto]
      assert_equal BigDecimal("150"), divergencia[:saldo_nosso]
      assert_equal BigDecimal("250"), divergencia[:saldo_deles]
    end

    # O SALDO INICIAL não é divergência.
    #
    # Eu comecei o saldo corrente em zero, e no dado real do cliente a PRIMEIRA linha do
    # razão saiu acusada como divergência com um salto de −R$ 1.145,37 — que era o saldo
    # que a conta tinha em 30/06, de vendas anteriores à nossa janela. Chamar isso de
    # divergência manda alguém investigar um movimento correto.
    #
    # Aqui a conta já tinha R$ 200 antes do primeiro movimento que importamos, e nada está
    # errado: os dois lados andam juntos.
    test "saldo que a conta já tinha não é apontado como divergência" do
      linha(source: "111", saldo: 250, quando: 4.days.ago,
            partes: [ [ :sale, :credit, 50 ] ])

      linha(source: "222", saldo: 300, quando: 3.days.ago,
            partes: [ [ :sale, :credit, 50 ] ])

      resultado = extrato

      assert_equal BigDecimal("200"), resultado[:saldo_inicial]
      assert_nil resultado[:primeira_divergencia]

      # E o saldo corrente parte dele, senão a coluna toda ficaria deslocada.
      assert_equal BigDecimal("250"), resultado[:linhas].last[:saldo_nosso]
    end

    # Sem saldo informado pela plataforma não há saldo inicial a deduzir, e começar do zero
    # é o melhor que existe — mas aí também não há com o que comparar.
    test "sem saldo da plataforma o inicial é zero" do
      criar_lancamento(tenant: @tenant, conta: @conta, valor: 10, ocorrido_em: 1.day.ago)

      resultado = extrato

      assert_equal BigDecimal("0"), resultado[:saldo_inicial]
      assert_nil resultado[:primeira_divergencia]
    end

    # Depois da primeira divergência todas as linhas estão distantes. O que conta é o
    # SALTO: duas divergências são dois saltos, e as linhas entre elas não são problema.
    test "lista cada salto, e não cada linha distante" do
      linha(source: "111", saldo: 100, quando: 6.days.ago, partes: [ [ :sale, :credit, 100 ] ])

      # Salto 1: eles creditam 150, nós 50.
      linha(source: "222", saldo: 250, quando: 5.days.ago, partes: [ [ :sale, :credit, 50 ] ])

      # Distante, mas em paz: o movimento bate dos dois lados.
      linha(source: "333", saldo: 300, quando: 4.days.ago, partes: [ [ :sale, :credit, 50 ] ])

      # Salto 2, maior: eles debitam 300 e nós 50.
      linha(source: "444", saldo: 0, quando: 3.days.ago, partes: [ [ :fee, :debit, 50 ] ])

      resultado = extrato

      assert_equal 2, resultado[:divergencias].size
      # Ordenada pelo tamanho do salto: a maior primeiro, porque é por onde se começa.
      assert_equal "444", resultado[:divergencias].first[:referencia]
      # E a primeira ainda é a primeira NO TEMPO, que responde "quando começou".
      assert_equal "222", resultado[:primeira_divergencia][:referencia]
    end

    # O artefato que eu quase entreguei como achado: várias linhas no MESMO instante,
    # aplicadas por nós numa ordem e pelo marketplace na ordem dele. Comparando linha a
    # linha, o instante gera dois saltos opostos que quase se cancelam — no dado real
    # apareceu como `payment +9.829,95` e `reserve_for_dispute −9.821,95` no mesmo dia.
    #
    # Dentro do instante a ordem não importa: o que importa é o saldo ao final dele.
    test "linhas no mesmo instante não geram saltos opostos falsos" do
      agora = 3.days.ago.change(usec: 0)

      # Nós somamos o crédito primeiro; o marketplace debitou primeiro. Os saldos
      # intermediários discordam, o final não.
      linha(source: "111", saldo: 900, quando: agora,
            partes: [ [ :sale, :credit, 1000 ] ])

      linha(source: "222", saldo: 900, quando: agora, descricao: "reserve_for_dispute",
            partes: [ [ :dispute, :debit, 100 ] ])

      resultado = extrato

      assert_empty resultado[:divergencias],
                   "ordem dentro do mesmo instante não é divergência"
      assert_nil resultado[:primeira_divergencia]
    end

    # E o contrário continua valendo: se o saldo ao FINAL do instante não bate, é real.
    #
    # O instante tem que ser o SEGUNDO. No primeiro não pode haver divergência por
    # construção: é dele que o saldo inicial é deduzido.
    test "instante cujo saldo final não bate continua sendo divergência" do
      linha(source: "000", saldo: 100, quando: 5.days.ago, partes: [ [ :sale, :credit, 100 ] ])

      agora = 3.days.ago.change(usec: 0)

      # Movemos +900 no instante; eles saem de 100 para 1400, ou seja +1300.
      linha(source: "111", saldo: 1400, quando: agora, partes: [ [ :sale, :credit, 1000 ] ])
      linha(source: "222", saldo: 1400, quando: agora, descricao: "reserve_for_dispute",
            partes: [ [ :dispute, :debit, 100 ] ])

      divergencias = extrato[:divergencias]

      assert_equal 1, divergencias.size
      assert_equal BigDecimal("-400"), divergencias.first[:salto]
      # O nome do instante traz os dois movimentos: o culpado pode ser qualquer um deles.
      assert_equal "payment + reserve_for_dispute", divergencias.first[:movimento]
    end

    test "sem divergência nenhuma não aponta nada" do
      linha(source: "111", saldo: 100, quando: 4.days.ago, partes: [ [ :sale, :credit, 100 ] ])
      linha(source: "222", saldo: 160, quando: 3.days.ago, partes: [ [ :sale, :credit, 60 ] ])

      assert_nil extrato[:primeira_divergencia]
    end

    # O caso do cliente: débito de reserva de disputa liquidado, crédito da volta que
    # nunca entrou. O agrupamento por TIPO é o que mostra qual movimento drena a conta.
    test "agrupa por tipo de movimento, com crédito, débito e pendentes" do
      linha(source: "111", saldo: 100, quando: 4.days.ago,
            partes: [ [ :sale, :credit, 100 ] ])

      linha(source: "222", saldo: 20, quando: 3.days.ago, descricao: "reserve_for_dispute",
            partes: [ [ :dispute, :debit, 80 ] ])

      reserva = extrato[:por_tipo].find { |t| t[:movimento] == "reserve_for_dispute" }

      assert_equal 1, reserva[:quantidade]
      assert_equal BigDecimal("80"), reserva[:debito]
      assert_equal BigDecimal("0"), reserva[:credito]
      assert_equal BigDecimal("-80"), reserva[:resultado]
    end

    # Lançamento não liquidado não entra no disponível. Quando um tipo tem débito
    # liquidado e crédito pendente, o saldo fica negativo sem nada estar errado no
    # dinheiro — e a tela precisa dizer isso em vez de mostrar o número seco.
    test "conta os pendentes por tipo" do
      pendente = criar_lancamento(tenant: @tenant, conta: @conta, tipo: :sale,
                                  direcao: :credit, valor: 100, status: :pending)

      pendente.update!(raw_payload: { "DESCRIPTION" => "payment", "SOURCE_ID" => "999" })

      venda = extrato[:por_tipo].find { |t| t[:movimento] == "payment" }

      assert_equal 1, venda[:pendentes]
    end

    # Lançamento manual não tem `SOURCE_ID`. Sem o cuidado, todos eles viravam UM grupo e
    # o extrato mostrava uma linha só com a soma da vida inteira.
    test "lançamento sem referência do relatório é a sua própria linha" do
      criar_lancamento(tenant: @tenant, conta: @conta, valor: 10, ocorrido_em: 2.days.ago)
      criar_lancamento(tenant: @tenant, conta: @conta, valor: 20, ocorrido_em: 1.day.ago)

      assert_equal 2, extrato[:total_de_linhas]
    end

    # A tela mostra as ÚLTIMAS, que é o que alguém quer ver primeiro, e diz o total para
    # a pessoa saber que existe mais.
    test "o limite corta as mais antigas e o total continua inteiro" do
      5.times do |i|
        linha(source: "s#{i}", saldo: (i + 1) * 10, quando: (10 - i).days.ago,
              partes: [ [ :sale, :credit, 10 ] ])
      end

      resultado = extrato(limite: 2)

      assert_equal 5, resultado[:total_de_linhas]
      assert_equal 2, resultado[:linhas].size
      # Mais recente primeiro.
      assert_equal "s4", resultado[:linhas].first[:referencia]
    end
  end
end
