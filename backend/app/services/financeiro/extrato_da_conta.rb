module Financeiro
  # O extrato da conta virtual: movimento por movimento, com o saldo corrente do nosso
  # razão ao lado do saldo que o próprio marketplace calculou.
  #
  # Existe por uma pergunta do cliente: "na conta virtual Disponível −R$ 24.946,11, como
  # assim?" Saldo negativo numa conta real é impossível, e a tela mostrava só o número.
  # Para descobrir de onde vinha eu escrevi script atrás de script — e a resposta, quando
  # chegou, era uma linha de extrato: débitos de reserva de disputa sem o crédito da volta.
  #
  # A pergunta "como o saldo chegou aqui" é de extrato, não de diagnóstico. Uma tela que a
  # responde tira o script do caminho.
  #
  # O QUE FAZ ESTE EXTRATO SER ÚTIL é a coluna do marketplace. `BALANCE_AMOUNT` é o saldo
  # corrente que o Mercado Livre mantém, linha a linha, e é fonte independente da nossa.
  # Onde os dois se separam está o movimento que falta ou que sobra — e é UM movimento, não
  # um total. Total só diz que há problema; a primeira divergência diz qual é.
  class ExtratoDaConta
    # Uma linha do relatório vira VÁRIOS lançamentos nossos — a venda pelo bruto e uma
    # dedução para cada taxa —, e todos carregam o MESMO `BALANCE_AMOUNT`, porque o saldo
    # do marketplace se move uma vez por linha.
    #
    # Comparar lançamento a lançamento acusaria divergência em todo `-FEE`, o que é falso.
    # A comparação é por LINHA, e a linha é `SOURCE_ID` + instante.
    CHAVE_DA_LINHA = %w[SOURCE_ID DATE].freeze

    # Dez centavos: o relatório arredonda e o nosso razão soma BigDecimal.
    TOLERANCIA = BigDecimal("0.10")

    def initialize(tenant:, platform_account:, desde: nil, ate: nil, limite: 200)
      @tenant = tenant

      @platform_account = platform_account

      @desde = desde

      @ate = ate

      @limite = limite.to_i.clamp(1, 1000)
    end

    def call
      {
        conta: {
          id: platform_account.id,
          nome: platform_account.name,
          plataforma: platform_account.platform
        },
        saldo: BalanceEngine.new(tenant: tenant, platform_account: platform_account).call,
        # `saldo inicial + entradas − saídas` é a conta que responde "o dinheiro chegou?",
        # e até aqui ela não existia porque a primeira parcela não existia.
        saldo_inicial: saldo_inicial,
        por_tipo: por_tipo,
        # A resposta para "como o saldo chegou aqui", quando existe.
        primeira_divergencia: divergencias.first,
        # TODAS elas, da maior para a menor. Cada salto é um movimento em que o nosso
        # razão e o marketplace discordam, e cada um tem causa própria — a primeira
        # responde "quando começou", a lista responde "o que consertar".
        divergencias: divergencias.sort_by { |linha| -linha[:salto].abs }.first(limite),
        linhas: linhas_recentes,
        total_de_linhas: linhas.size
      }
    end

    private

    attr_reader :tenant, :platform_account, :desde, :ate, :limite

    # Por TIPO de movimento, e não só o total: é assim que se vê qual movimento está
    # drenando a conta. Foi `reserve_for_dispute` no caso do cliente — R$ 85.442,06 de
    # débito cujo crédito de volta nunca entrou.
    def por_tipo
      agrupado = lancamentos.group_by { |e| descricao_de(e) }

      agrupado.map do |descricao, lista|
        creditos = lista.select { |e| e.direction == "credit" }
        debitos = lista.select { |e| e.direction == "debit" }

        {
          movimento: descricao,
          quantidade: lista.size,
          credito: soma(creditos),
          debito: soma(debitos),
          resultado: soma(creditos) - soma(debitos),
          # Lançamento não liquidado não entra no disponível. Quando um tipo tem débito
          # liquidado e crédito pendente, o saldo fica negativo sem nada estar errado no
          # dinheiro — e é isso que a tela precisa dizer em vez de mostrar o número seco.
          pendentes: lista.count { |e| e.status != "settled" }
        }
      end.sort_by { |linha| -(linha[:credito] + linha[:debito]) }
    end

    # O saldo que a conta JÁ TINHA antes do primeiro movimento que importamos.
    #
    # Começar o saldo corrente em zero foi um erro meu, e ele apareceu no dado real: a
    # primeira linha do razão do cliente saiu acusada como "primeira divergência" com um
    # salto de −R$ 1.145,37, quando aquilo era o saldo que a conta tinha em 30/06 de
    # vendas anteriores à nossa janela. Chamar saldo inicial de divergência manda alguém
    # investigar um movimento que está correto.
    #
    # O marketplace informa o saldo DEPOIS de cada linha. Tirando dele o movimento da
    # primeira linha, sobra o saldo de antes. É a única coisa nesta classe que não é soma
    # do que temos — e é justamente a parcela que faltava para a conta
    # `saldo inicial + créditos − saques` existir.
    def saldo_inicial
      return @saldo_inicial if defined?(@saldo_inicial)

      # Do primeiro INSTANTE inteiro, e não da primeira linha. Quando o instante tem
      # várias linhas, o saldo que o marketplace informa nele é o de DEPOIS de todas —
      # deduzir só o movimento da primeira deixa o resto como falsa divergência.
      @saldo_inicial = begin
        grupos = agrupar_por_linha.values

        if grupos.empty?
          BigDecimal("0")
        else
          instante = grupos.first.first.occurred_at

          primeiros = grupos.take_while { |grupo| grupo.first.occurred_at == instante }

          deles = primeiros.reverse.filter_map { |grupo| saldo_do_marketplace(grupo) }.first

          deles ? (deles - primeiros.sum(BigDecimal("0")) { |g| movimento_de(g) }).round(2) : BigDecimal("0")
        end
      end
    end

    # As linhas do extrato, em ordem de data, com os dois saldos correntes.
    def linhas
      @linhas ||= begin
        corrente = saldo_inicial

        agrupar_por_linha.map do |chave, grupo|
          movimento = movimento_de(grupo)

          corrente += movimento

          deles = saldo_do_marketplace(grupo)

          {
            ocorrido_em: grupo.first.occurred_at,
            movimento: descricao_de(grupo.first),
            referencia: chave.first,
            pedido: grupo.filter_map { |e| e.order&.external_id }.first,
            # O que o marketplace escreveu na linha. `MELIPAYMENTS-COLLECTIONATTEMPT` é
            # cobrança de dívida e não tem pedido nenhum — sem esta coluna a linha
            # aparecia como um débito sem origem.
            referencia_externa: grupo.filter_map { |e| payload(e)["EXTERNAL_REFERENCE"].presence }.first,
            lancamentos: grupo.size,
            valor: movimento,
            saldo_nosso: corrente,
            saldo_deles: deles,
            # Só faz sentido onde o marketplace informou o saldo dele.
            distancia: deles && (corrente - deles).round(2),
            pendentes: grupo.count { |e| e.status != "settled" }
          }
        end
      end
    end

    # As linhas em que os dois saldos se separam, em ordem de data.
    #
    # O que identifica cada uma é o SALTO, não a distância acumulada: depois da primeira
    # divergência todas as linhas estão distantes, porque o erro se carrega para frente.
    # Ordenar pela distância listaria as 4.900 linhas seguintes como se cada uma fosse um
    # problema.
    #
    # Medido no dado real: das 4.940 linhas do cliente, a distância final é R$ 3.050,44 e
    # ela vem de poucos saltos — o primeiro é uma tentativa de cobrança do Mercado Livre
    # (`MELIPAYMENTS-COLLECTIONATTEMPT`) que debitou R$ 1.325,02 num saldo de R$ 965,72:
    # o saldo DELES foi a zero, o nosso a negativo, e os R$ 359,30 de diferença são
    # dívida que o marketplace não conseguiu cobrar.
    # A comparação é por INSTANTE, e não por linha. Isto não é detalhe.
    #
    # Quando várias linhas do relatório caem no mesmo instante, nós aplicamos os
    # movimentos numa ordem e o marketplace calculou o saldo dele na ordem DELE. Comparando
    # linha a linha, cada instante desses gera DOIS saltos opostos que quase se cancelam —
    # e eu quase entreguei 40 "divergências" das quais metade era isso. A assinatura era
    # visível: `payment +9.829,95` e `reserve_for_dispute −9.821,95` no mesmo dia.
    #
    # Dentro de um instante a ordem não importa: o que importa é o saldo ao final dele. O
    # nosso é a soma dos movimentos do instante; o deles é o `BALANCE_AMOUNT` da ÚLTIMA
    # linha, e "última" é por `id`, que segue a ordem das linhas do arquivo porque a
    # ingestão lê o CSV de cima para baixo.
    def divergencias
      @divergencias ||= begin
        anterior = BigDecimal("0")

        por_instante.filter_map do |linha|
          distancia = linha[:distancia]

          next if distancia.nil?

          salto = (distancia - anterior).round(2)

          anterior = distancia

          next if salto.abs <= TOLERANCIA

          linha.merge(salto: salto)
        end
      end
    end

    # Uma entrada por instante, com o saldo dos dois lados ao final dele.
    def por_instante
      linhas.group_by { |linha| linha[:ocorrido_em] }.map do |_, grupo|
        ultima = grupo.last

        # O saldo deles ao final do instante: o da última linha que o informou.
        deles = grupo.reverse.find { |l| l[:saldo_deles] }&.fetch(:saldo_deles)

        ultima.merge(
          # O movimento e a descrição do instante inteiro, para a tela nomear o culpado.
          valor: grupo.sum(BigDecimal("0")) { |l| l[:valor] },
          movimento: grupo.map { |l| l[:movimento] }.uniq.join(" + "),
          lancamentos: grupo.sum { |l| l[:lancamentos] },
          saldo_deles: deles,
          distancia: deles && (ultima[:saldo_nosso] - deles).round(2)
        )
      end
    end

    def linhas_recentes = linhas.last(limite).reverse

    # Uma linha do relatório por `SOURCE_ID` + instante. Sem `SOURCE_ID` — lançamento
    # manual, plataforma que não informa — cada lançamento é a sua própria linha, senão
    # todos eles virariam um grupo só.
    def agrupar_por_linha
      lancamentos.group_by do |lancamento|
        cru = payload(lancamento)

        chave = CHAVE_DA_LINHA.map { |coluna| cru[coluna].to_s }

        chave.any?(&:present?) ? chave : [ "lancamento-#{lancamento.id}", "" ]
      end
    end

    def movimento_de(grupo)
      soma(grupo.select { |e| e.direction == "credit" }) -
        soma(grupo.select { |e| e.direction == "debit" })
    end

    def saldo_do_marketplace(grupo)
      bruto = grupo.filter_map { |e| payload(e)["BALANCE_AMOUNT"].presence }.first

      bruto&.to_d
    end

    # `DESCRIPTION` diz o que o movimento É; `entry_type` diz o papel dele no nosso razão.
    # Confundir os dois foi a regressão que pôs reserva de disputa e frete no razão como
    # receita, então aqui os dois aparecem.
    def descricao_de(lancamento)
      payload(lancamento)["DESCRIPTION"].presence || lancamento.entry_type
    end

    def payload(lancamento)
      cru = lancamento.raw_payload

      cru.is_a?(Hash) ? cru : {}
    end

    def soma(lista) = lista.sum(BigDecimal("0")) { |e| e.amount.to_d }

    def lancamentos
      @lancamentos ||= begin
        escopo = FinancialEntry
                   .where(tenant_id: tenant.id, platform_account_id: platform_account.id)
                   .includes(:order)

        escopo = escopo.where(occurred_at: desde.beginning_of_day..) if desde

        escopo = escopo.where(occurred_at: ..ate.end_of_day) if ate

        escopo.order(:occurred_at, :id).to_a
      end
    end
  end
end
