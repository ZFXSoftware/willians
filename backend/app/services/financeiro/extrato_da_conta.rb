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
        por_tipo: por_tipo,
        # A resposta para "como o saldo chegou aqui", quando existe.
        primeira_divergencia: primeira_divergencia,
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

    # As linhas do extrato, em ordem de data, com os dois saldos correntes.
    def linhas
      @linhas ||= begin
        corrente = BigDecimal("0")

        agrupar_por_linha.map do |chave, grupo|
          movimento = soma(grupo.select { |e| e.direction == "credit" }) -
                      soma(grupo.select { |e| e.direction == "debit" })

          corrente += movimento

          deles = saldo_do_marketplace(grupo)

          {
            ocorrido_em: grupo.first.occurred_at,
            movimento: descricao_de(grupo.first),
            referencia: chave.first,
            pedido: grupo.filter_map { |e| e.order&.external_id }.first,
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

    # A PRIMEIRA linha em que os dois saldos se separam, e o quanto se separaram nela.
    #
    # Depois da primeira, todas divergem — o erro é cumulativo. Reportar a última, ou
    # todas, esconde a única que responde a pergunta.
    def primeira_divergencia
      anterior = BigDecimal("0")

      linhas.each do |linha|
        distancia = linha[:distancia]

        next if distancia.nil?

        # O SALTO, e não a distância acumulada: é o salto que aponta o movimento culpado.
        salto = (distancia - anterior).round(2)

        if salto.abs > TOLERANCIA
          return linha.merge(salto: salto)
        end

        anterior = distancia
      end

      nil
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
