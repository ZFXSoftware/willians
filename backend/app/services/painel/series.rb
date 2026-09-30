module Painel
  # As séries que o painel desenha: por dia, por canal, por status e a composição do bruto.
  #
  # Separado do `Resumo` porque são perguntas diferentes: ele responde "quanto tem agora",
  # e isto responde "como foi ao longo do tempo e de onde vem". Juntar faria toda abertura
  # do painel pagar o custo das duas.
  class Series
    JANELA_PADRAO = 90

    # Quantos canais e status a rosca mostra antes de dobrar o resto em "Outros".
    #
    # Seis é o teto de fatia legível: passando disso as fatias vizinhas encostam e a
    # comparação vira adivinhação.
    TETO_DE_FATIAS = 6

    # O sufixo do `external_id` diz QUAL dedução a linha é. O relatório manda a venda e
    # cada taxa em linhas separadas, e todas carregam uma cópia da linha inteira — somar
    # `GROSS_AMOUNT` em todas elas conta a mesma venda quatro vezes. Medido: dá R$ 2,25
    # milhões onde o bruto real do período é R$ 482 mil.
    DEDUCOES = {
      "comissao" => "-FEE",
      "frete" => "-SHIP",
      "parcelamento" => "-FIN"
    }.freeze

    def initialize(tenant:, dias: JANELA_PADRAO)
      @tenant = tenant

      @dias = dias.to_i.clamp(7, 365)
    end

    def call
      {
        periodo: { de: de, ate: ate, dias: dias },
        por_dia: por_dia,
        por_canal: por_canal,
        conciliacao: conciliacao,
        composicao: composicao
      }
    end

    private

    attr_reader :tenant, :dias

    def ate = @ate ||= Date.current

    def de = @de ||= ate - dias

    # Uma linha por dia do período, inclusive os dias sem movimento.
    #
    # Sem os dias vazios a linha do gráfico "pula" o fim de semana e encurta o eixo, o
    # que faz a série parecer mais densa do que é.
    def por_dia
      vendas = vendas_por_dia

      saques = saques_por_dia

      (de..ate).map do |dia|
        venda = vendas[dia] || [ 0, BigDecimal("0") ]

        {
          dia: dia,
          vendas_quantidade: venda.first,
          vendas_valor: venda.last.to_s,
          saques: (saques[dia] || BigDecimal("0")).to_s
        }
      end
    end

    # `vendas_reais` exclui o que foi marcado como não-venda — pedido cancelado, depósito
    # na conta, linha que não era venda. Sem isso o gráfico mostraria receita que a
    # conciliação já não reconhece, e as duas telas contariam histórias diferentes.
    #
    # A data é `expected_on`, quando o dinheiro fica disponível: está preenchida em 4.201
    # de 4.201 recebíveis, enquanto `released_on` falta em 87.
    def vendas_por_dia
      ReceivableUnit
        .vendas_reais
        .where(tenant_id: tenant.id)
        .where(expected_on: de..ate)
        .group(:expected_on)
        .pluck(Arel.sql("expected_on, COUNT(*), COALESCE(SUM(gross_amount), 0)"))
        .to_h { |dia, quantas, valor| [ dia, [ quantas, valor.to_d ] ] }
    end

    # O que SAIU para o banco, pelo lançamento de liquidação — e não pelo bruto do lote,
    # que é o valor das vendas da janela e costuma ser bem diferente.
    def saques_por_dia
      PayoutBatch
        .where(tenant_id: tenant.id, paid_at: de.beginning_of_day..ate.end_of_day)
        .joins("INNER JOIN financial_entries ON financial_entries.id = payout_batches.financial_entry_id")
        .group(Arel.sql("DATE(payout_batches.paid_at)"))
        .sum(Arel.sql("financial_entries.amount"))
        .transform_keys { |dia| dia.is_a?(Date) ? dia : Date.parse(dia.to_s) }
        .transform_values(&:to_d)
    end

    # Receita por canal de venda, lida do intermediador declarado na NF-e.
    #
    # É a única leitura que enxerga o negócio inteiro: a conciliação de repasses só olha o
    # Mercado Livre. O nome cru não serve de rótulo — no cliente ele aparece como
    # "1333228810" e "Alma teen" —, então passa pelo mapeamento de canal.
    def por_canal
      brutos = Invoice
                 .where(tenant_id: tenant.id)
                 .where.not(status: :cancelled)
                 .where(operation_type: :sale)
                 .where(issued_at: de.beginning_of_day..ate.end_of_day)
                 .group(Arel.sql("invoices.metadata->'intermediador'->>'nome'"))
                 .sum(:total_amount)

      por_rotulo = Hash.new(BigDecimal("0"))

      canais = {}

      brutos.each do |nome, valor|
        canal = Fiscal::Tiny::Canal.para(nome, tenant: tenant)

        # Sem mapeamento, vale o NOME CRU — e não um balde "sem canal".
        #
        # No cliente os não mapeados são "1333228810" (o id do vendedor no Mercado Livre,
        # que é como as notas emitidas por ele saem), "Alma teen" e "759040086", somando
        # R$ 412 mil. Jogados num balde só, eles viravam a MAIOR fatia da rosca, com um
        # rótulo que não diz nada e não dá o que fazer. Pelo nome cru, quem olha reconhece
        # e vai mapear em Configurações.
        rotulo = canal.present? ? rotulo_de(canal) : nome.presence || "Sem intermediador"

        canais[rotulo] ||= canal

        por_rotulo[rotulo] += valor.to_d
      end

      dobrar(por_rotulo.map { |rotulo, valor| { canal: canais[rotulo], rotulo: rotulo, receita: valor } })
    end

    # Quantos repasses em cada desfecho, no estado ATUAL — um registro por repasse, e não
    # o histórico de conferências.
    def conciliacao
      atuais = ConciliacaoRegistro.where(id: ConciliacaoRegistro.ids_dos_ultimos(tenant.id))

      atuais.group(:status).count.map { |status, quantas| { status: status, quantidade: quantas } }
            .sort_by { |linha| -linha[:quantidade] }
    end

    # Para onde vai o bruto: o que sobra e o que cada dedução leva.
    #
    # Parte-e-todo de verdade — `líquido + comissão + frete + parcelamento` é o bruto —,
    # que é a única coisa que uma rosca sabe mostrar.
    def composicao
      bruto = recebiveis.sum(:gross_amount).to_d

      return [] if bruto.zero?

      deducoes = DEDUCOES.map do |nome, sufixo|
        valor = FinancialEntry
                  .where(tenant_id: tenant.id, entry_type: :fee)
                  .where(occurred_at: de.beginning_of_day..ate.end_of_day)
                  .where("external_id LIKE ?", "%#{sufixo}")
                  .sum(:amount)
                  .to_d

        { parte: nome, valor: valor }
      end

      sobra = bruto - deducoes.sum(BigDecimal("0")) { |d| d[:valor] }

      # Dedução maior que o bruto deixaria a rosca com uma fatia negativa, que não
      # existe. Acontece quando a janela pega taxa de venda liberada antes dela.
      [ { parte: "liquido", valor: [ sobra, BigDecimal("0") ].max } ] + deducoes
    end

    def recebiveis
      ReceivableUnit
        .vendas_reais
        .where(tenant_id: tenant.id)
        .where(expected_on: de..ate)
    end

    # As maiores, e o resto somado em "Outros": rosca com mais de seis fatias tem fatias
    # que encostam, e aí a comparação vira adivinhação.
    def dobrar(linhas)
      ordenadas = linhas.sort_by { |linha| -linha[:receita] }

      return ordenadas.map { |l| l.merge(receita: l[:receita].to_s) } if ordenadas.size <= TETO_DE_FATIAS

      cabeca = ordenadas.first(TETO_DE_FATIAS - 1)

      resto = ordenadas.drop(TETO_DE_FATIAS - 1)

      cabeca.map { |l| l.merge(receita: l[:receita].to_s) } +
        [ { canal: nil, rotulo: "Outros (#{resto.size})",
            receita: resto.sum(BigDecimal("0")) { |l| l[:receita] }.to_s } ]
    end

    def rotulo_de(canal)
      return "Sem canal mapeado" if canal.blank?

      Fiscal::Tiny::Canal::OPCOES.find { |o| o[:canal] == canal }&.fetch(:rotulo) || canal
    end
  end
end
