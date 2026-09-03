module Conciliacao
  # Concilia os repasses (PayoutBatch) de uma conta de marketplace contra os
  # títulos a receber que o OMIE reconhece na mesma janela.
  #
  # A comparação é bruto-a-bruto: `payout.gross_amount` é a soma dos valores
  # brutos dos recebíveis liquidados naquele repasse, e é isso que corresponde ao
  # `valor_documento` do título no OMIE. As taxas ficam registradas no metadata
  # do registro para análise posterior.
  class ConciliacaoEngine
    BATCH_SIZE = 500

    SOURCE = "omie".freeze

    LOG_PREFIX = "[ConciliacaoEngine]".freeze

    # O título é emitido no OMIE na data da venda, mas o repasse cai semanas
    # depois. Buscar títulos na mesma janela dos repasses não acharia nada.
    EMISSION_LOOKBACK_DAYS = 90

    STATUS_POR_RESULTADO = {
      ok: "matched",
      divergente: "divergent",
      nao_encontrado: "manual_review"
    }.freeze

    TIPO_DIVERGENCIA = {
      divergente: "valor_divergente",
      nao_encontrado: "titulo_nao_encontrado"
    }.freeze

    # Índice de títulos do OMIE por referência. Fica na classe porque o serviço
    # carrega uma vez e injeta em todas as contas da execução.
    def self.carregar_totais(client:, start_date:, end_date:)
      Omie::Readers::ReceivableTotals
        .new(client: client)
        .call(
          start_date: start_date.to_date - EMISSION_LOOKBACK_DAYS,
          end_date: end_date
        )
    end

    def initialize(
      tenant:,
      platform_account:,
      start_date:,
      end_date:,
      omie_client: nil,
      omie_totals: nil
    )
      @tenant = tenant

      @platform_account = platform_account

      @start_date = start_date.to_date

      @end_date = end_date.to_date

      @omie_client = omie_client || default_client

      # Os títulos são da EMPRESA, não da conta de marketplace. Quando várias
      # contas são conciliadas na mesma execução, o índice é carregado uma vez
      # e injetado aqui — buscar por conta repetiria a mesma requisição e o
      # Omie bloqueia por consumo redundante.
      @omie_totals = omie_totals

      @counters = Hash.new(0)
    end

    def call
      create_run!

      omie_totals = fetch_omie_totals

      process_payouts!(omie_totals)

      finalize_run!(omie_totals)

      run
    rescue StandardError => e
      fail_run!(e)

      raise
    end

    private

    attr_reader :tenant,
                :platform_account,
                :start_date,
                :end_date,
                :omie_client,
                :omie_totals,
                :counters,
                :run

    def default_client
      Omie::Client.configured? ? Omie::Client.new : Omie::FakeOmieClient.new
    end

    def create_run!
      @run = ConciliationRun.create!(
        tenant: tenant,

        platform_account: platform_account,

        platform: platform_account.platform,

        source: SOURCE,

        status: :processing,

        started_at: Time.current
      )
    end

    # Já veio carregado pelo serviço quando há mais de uma conta na execução.
    def fetch_omie_totals
      omie_totals || self.class.carregar_totais(
        client: omie_client,
        start_date: start_date,
        end_date: end_date
      )
    end

    def process_payouts!(omie_totals)
      registros = []

      divergencias = []

      payouts.find_each(batch_size: BATCH_SIZE) do |payout|
        resultado = conciliar(payout, omie_totals)

        counters[:total] += 1

        counters[resultado.status] += 1

        counters[:com_nf] += 1 if notas_fiscais_for(payout).any?

        resolvidos << payout.financial_entry_id if resultado.ok? && payout.financial_entry_id

        registros << registro_row(payout, resultado)

        divergencia = divergencia_row(payout, resultado)

        divergencias << divergencia if divergencia

        if registros.size >= BATCH_SIZE
          flush!(registros, divergencias)
        end
      end

      flush!(registros, divergencias)

      fechar_resolvidas!
    end

    # Divergência que voltou a bater se resolve sozinha.
    #
    # Sem isto, "Título não encontrado" ficava aberta para sempre: o título
    # aparece no OMIE, o repasse passa a conferir, e a tela continua acusando
    # sete divergências que já não existem. A conciliação de SALDO já fazia
    # isso; a de repasses, não.
    def fechar_resolvidas!
      return if resolvidos.empty?

      fechadas =
        DivergenceReport
          .where(tenant_id: tenant.id, status: :open, financial_entry_id: resolvidos.to_a)
          .update_all(
            status: "resolved",
            resolved_at: Time.current,
            resolution_notes: "Passou a conferir com o OMIE na execução de #{Date.current}.",
            updated_at: Time.current
          )

      counters[:divergencias_fechadas] += fechadas

      resolvidos.clear
    end

    def resolvidos
      @resolvidos ||= Set.new
    end

    def flush!(registros, divergencias)
      ConciliacaoRegistro.insert_all!(registros) if registros.any?

      if divergencias.any?
        DivergenceReport.insert_all(
          divergencias,
          unique_by: :idx_divergence_reports_unique
        )
      end

      registros.clear

      divergencias.clear
    end

    def conciliar(payout, omie_totals)
      ConciliadorRecebimentos.conciliar(
        valor_interno: valor_interno_for(payout),

        valor_omie: valor_omie_for(payout, omie_totals)
      )
    end

    def valor_interno_for(payout)
      (payout.gross_amount || payout.net_amount).to_d
    end

    def valor_omie_for(payout, omie_totals)
      cobertura = cobertura_de(payout, omie_totals)

      return if cobertura[:encontradas].empty?

      # Comparação PARCIAL não é comparação.
      #
      # Um repasse junta uma centena de vendas. Se só três delas têm título no
      # OMIE, somar essas três e comparar com o repasse inteiro produz uma
      # diferença enorme que não é divergência nenhuma — é a ausência das
      # outras noventa e sete. Alguém lendo isso concluiria que falta dinheiro.
      #
      # Enquanto a cobertura não for completa, não há o que comparar.
      #
      # Salvo quando o que falta são notas que NUNCA vão ter título: nota
      # emitida sem valor, que o OMIE recusa. Esperar por elas é esperar para
      # sempre, e o repasse ficava em "comparação incompleta" sem prazo e sem
      # explicação. Comparar dizendo o que ficou de fora é melhor: a diferença
      # que aparece é dinheiro que entrou sem documento fiscal, e isso é
      # divergência de verdade.
      return unless cobertura[:completa] || cobertura[:completa_com_exclusoes]

      cobertura[:encontradas].sum(BigDecimal("0")) { |ref| omie_totals[ref] }
    end

    # Guardada por repasse porque a observação, montada depois, precisa dela
    # para dizer QUAL dos casos é.
    #
    # O denominador são as NOTAS, e não os recebíveis.
    #
    # Contar recebíveis parecia certo — um repasse de cem vendas com uma nota
    # só não pode passar por cobertura completa — mas quebra no pacote do
    # Mercado Livre: quando o comprador leva dois itens, as duas vendas
    # compartilham UMA nota fiscal. O repasse tinha dois recebíveis e uma
    # referência, `1 == 2` nunca era verdade, e ele ficava em "comparação
    # incompleta" para sempre por estar certo.
    def cobertura_de(payout, omie_totals)
      @coberturas ||= {}

      @coberturas[payout.id] ||= calcular_cobertura(payout, omie_totals)
    end

    # Método próprio, e não um `begin` dentro do memo: ali `return` sai da
    # função sem guardar a cobertura, e `next` nem é válido — `begin/end` não é
    # bloco. Os dois já quebraram esta mesma linha hoje.
    def calcular_cobertura(payout, omie_totals)
        unidades = unidades_de(payout)

        # Venda sem nota continua sendo buraco: não há o que comparar com ela,
        # e ignorá-la faria a soma do OMIE ser confrontada com um repasse que
        # inclui vendas que ela não cobre.
        sem_nota = unidades.count { |unidade| unidade.invoice.blank? }

        por_nota = unidades.select(&:invoice).group_by(&:invoice)

        # Repasse em que NENHUMA venda tem nota fiscal.
        #
        # Acontece em lançamento manual e em conta sem integração fiscal: ali o
        # título do OMIE carrega a referência do recebível no número do
        # documento, e é por ela que se casa. Exigir nota nesse caso não
        # protegeria nada — apagaria a única chave que existe.
        #
        # Só vale quando NENHUMA tem: com metade das vendas com nota, aceitar a
        # referência das outras é a comparação parcial que este arquivo inteiro
        # existe para impedir.
        #
        # `next`, e não `return`: dentro de `||= begin ... end` o return sai do
        # MÉTODO sem atribuir a memória, e a observação, montada depois, lia
        # cobertura vazia.
        return cobertura_sem_notas(payout, unidades, omie_totals) if por_nota.empty?

        # Nota cujos recebíveis NÃO estão todos neste repasse.
        #
        # A nota do pacote vale pelas duas vendas. Se só uma delas caiu aqui,
        # somar o valor inteiro da nota contra um repasse que pagou metade
        # acusa uma diferença que não existe — o mesmo erro da cobertura
        # parcial, um nível abaixo.
        divididas = notas_divididas(por_nota)

        esperadas = por_nota.keys.filter_map { |nota| Omie::Readers::ReceivableTotals.normalizar(nota.number) }.uniq

        encontradas = esperadas.select { |ref| omie_totals.key?(ref) }

        # As que não vão chegar: nota emitida sem valor não vira título nunca.
        # Contá-las como "faltando" deixa o repasse esperando para sempre.
        recusadas = por_nota.keys.select(&:recusada_no_envio?)

        integra = unidades.any? && sem_nota.zero? && divididas.zero?

        completa = integra && esperadas.any? && encontradas.size == esperadas.size

        {
          referencias: esperadas.size,
          sem_nota: sem_nota,
          divididas: divididas,
          encontradas: encontradas,
          recusadas: recusadas,
          completa: completa,
          completa_com_exclusoes:
            !completa && integra && recusadas.any? &&
              (encontradas.size + recusadas.size) == esperadas.size
        }
    end

    def cobertura_sem_notas(payout, unidades, omie_totals)
      referencias = referencias_for(payout)

      encontradas = referencias.select { |ref| omie_totals.key?(ref) }

      {
        referencias: referencias.size,
        sem_nota: 0,
        divididas: 0,
        encontradas: encontradas,
        recusadas: [],
        completa: unidades.any? && encontradas.size == unidades.size,
        completa_com_exclusoes: false
      }
    end

    # Quantos recebíveis cada nota tem NO TOTAL, para saber se este repasse
    # levou todos. Uma consulta para o lote inteiro, não uma por nota.
    def notas_divididas(por_nota)
      return 0 if por_nota.empty?

      totais = ReceivableUnit
                 .where(tenant_id: tenant.id, invoice_id: por_nota.keys.map(&:id))
                 .group(:invoice_id)
                 .count

      por_nota.count { |nota, unidades| totais[nota.id].to_i > unidades.size }
    end

    def unidades_de(payout)
      payout
        .financial_entry_allocations
        .filter_map(&:receivable_unit)
        .uniq
    end

    def recebiveis_de(payout)
      payout
        .financial_entry_allocations
        .filter_map(&:receivable_unit_id)
        .uniq
    end

    # Um repasse é conciliado pelas referências dos recebíveis que ele liquidou.
    #
    # A PRIMEIRA referência é o número da nota fiscal, porque é por ele que o
    # índice do OMIE é montado (ver Omie::Readers::ReceivableTotals). Antes só
    # existia o `external_id` do recebível, que é identificador NOSSO — do lado
    # do marketplace, algo como MLREL-PAY-1-SALE. Ele não existe no OMIE, então
    # a comparação nunca podia casar e todo repasse saía como "sem título
    # correspondente".
    #
    # O external_id continua como último recurso: em repasse lançado à mão a
    # referência pode ter sido escrita no número do documento.
    def referencias_for(payout)
      notas = notas_fiscais_for(payout)

      return notas if notas.any?

      refs =
        payout
          .financial_entry_allocations
          .filter_map { |allocation| allocation.receivable_unit&.external_id }
          .uniq

      refs.presence || [ payout.external_id ].compact
    end

    def notas_fiscais_for(payout)
      payout
        .financial_entry_allocations
        .filter_map { |allocation| Omie::Readers::ReceivableTotals.normalizar(allocation.receivable_unit&.invoice&.number) }
        .uniq
    end

    def payouts
      PayoutBatch
        .where(
          tenant: tenant,
          platform_account: platform_account
        )
        .where(paid_at: start_date.beginning_of_day..end_date.end_of_day)
        .includes(financial_entry_allocations: { receivable_unit: :invoice })
    end

    # "Sem título correspondente" cobre dois casos com providências opostas:
    # nenhuma nota deste repasse chegou ao OMIE, ou ALGUMAS chegaram e as
    # outras não. O segundo se resolve terminando o envio; o primeiro pode ser
    # nota não emitida, elo com o pedido faltando, ou título de fato ausente.
    def observacao_de(payout, resultado)
      cobertura = @coberturas[payout.id] || {}

      if resultado.valor_omie.present?
        return resultado.mensagem unless cobertura[:completa_com_exclusoes]

        return "#{resultado.mensagem} #{exclusoes(cobertura)}".strip
      end

      encontradas = cobertura[:encontradas].to_a.size

      referencias = cobertura[:referencias].to_i

      # Cada motivo pede uma providência diferente, e "comparação incompleta"
      # sozinho manda todo mundo procurar no lugar errado.
      if cobertura[:sem_nota].to_i.positive?
        return "#{cobertura[:sem_nota]} venda(s) deste repasse não têm nota fiscal vinculada. " \
               "Sem elas, comparar o repasse com os títulos das outras acusaria uma " \
               "diferença que não existe."
      end

      if cobertura[:divididas].to_i.positive?
        return "#{cobertura[:divididas]} nota(s) deste repasse cobrem vendas que caíram em " \
               "repasses diferentes. O valor da nota é do conjunto, e este repasse pagou " \
               "só uma parte — comparar os dois acusaria diferença onde não há."
      end

      return resultado.mensagem if referencias.zero?

      if encontradas.zero?
        "Nenhuma das #{referencias} nota(s) deste repasse tem título no OMIE."
      else
        "Comparação incompleta: só #{encontradas} de #{referencias} nota(s) deste repasse " \
        "têm título no OMIE. Comparar o repasse inteiro com uma parte dos títulos " \
        "acusaria uma diferença que não existe. #{exclusoes(cobertura)}".strip
      end
    end

    # O que ficou de fora e não vai entrar.
    #
    # Sem nomear as notas, a frase vira mais uma espera sem prazo — e é
    # justamente o oposto: são as notas que alguém precisa ir corrigir no
    # Tiny para o repasse fechar.
    def exclusoes(cobertura)
      recusadas = cobertura[:recusadas].to_a

      return "" if recusadas.empty?

      numeros = recusadas.first(3).map(&:number).join(", ")

      resto = recusadas.size > 3 ? " e outras #{recusadas.size - 3}" : ""

      "#{recusadas.size} venda(s) ficaram de fora: a nota fiscal delas foi emitida sem " \
      "valor e não vira título (NF #{numeros}#{resto}). A diferença apontada é dinheiro " \
      "que entrou sem documento fiscal correspondente."
    end

    def registro_row(payout, resultado)
      now = Time.current

      {
        tenant_id: tenant.id,

        conciliation_run_id: run.id,

        payout_batch_id: payout.id,

        financial_entry_id: payout.financial_entry_id,

        status: STATUS_POR_RESULTADO.fetch(resultado.status),

        match_type: resultado.match_type&.to_s,

        confidence_score: resultado.confidence_score,

        valor: resultado.valor_interno,

        diferenca: resultado.diferenca,

        referencia: payout.external_id,

        descricao: "Repasse #{payout.external_id} x títulos OMIE",

        observacao: observacao_de(payout, resultado),

        conciliation_metadata: {
          valor_interno: resultado.valor_interno.to_s,
          valor_omie: resultado.valor_omie&.to_s,
          valor_liquido_repasse: payout.net_amount&.to_s,
          taxa_repasse: payout.fee_amount&.to_s,
          referencias: referencias_for(payout),
          base_comparacao: "bruto"
        },

        conciliated_at: now,

        created_at: now,

        updated_at: now
      }
    end

    # Divergências abertas não são recriadas a cada execução — o scheduler roda a
    # cada poucos minutos e duplicaria o backlog indefinidamente.
    def divergencia_row(payout, resultado)
      return if resultado.ok?

      return if payout.financial_entry_id.blank?

      tipo = TIPO_DIVERGENCIA.fetch(resultado.status)

      chave = [ payout.financial_entry_id, tipo ]

      return if divergencias_abertas.include?(chave)

      divergencias_abertas << chave

      now = Time.current

      {
        tenant_id: tenant.id,

        financial_entry_id: payout.financial_entry_id,

        divergence_type: tipo,

        status: "open",

        expected_amount: resultado.valor_omie,

        received_amount: resultado.valor_interno,

        difference_amount: resultado.diferenca,

        metadata: {
          conciliation_run_id: run.id,
          payout_batch_id: payout.id,
          referencias: referencias_for(payout),
          mensagem: resultado.mensagem
        },

        created_at: now,

        updated_at: now
      }
    end

    def divergencias_abertas
      @divergencias_abertas ||=
        DivergenceReport
          .where(
            tenant_id: tenant.id,
            status: :open,
            financial_entry_id: payouts.select(:financial_entry_id)
          )
          .pluck(:financial_entry_id, :divergence_type)
          .to_set
    end

    def finalize_run!(omie_totals)
      divergentes =
        counters[:divergente] + counters[:nao_encontrado]

      run.update!(
        status: :completed,

        finished_at: Time.current,

        total_entries: counters[:total],

        entries_processed: counters[:total],

        reconciled_entries: counters[:ok],

        matches_found: counters[:ok],

        divergent_entries: divergentes,

        divergences_found: divergentes,

        metadata: run.metadata.merge(
          "start_date" => start_date.to_s,
          "end_date" => end_date.to_s,
          "omie_referencias" => omie_totals.size,
          "nao_encontrados" => counters[:nao_encontrado],
          "repasses_com_nf" => counters[:com_nf]
        )
      )

      registrar(omie_totals)
    end

    # "Esperado (OMIE)" vazio tem três causas com providências diferentes, e a
    # tela mostra um traço para as três: o OMIE não devolveu título nenhum no
    # período; os repasses não têm nota fiscal do nosso lado (é a NF que casa
    # com o OMIE); ou têm, e o título não está lá.
    def registrar(omie_totals)
      Rails.logger.info(
        "#{LOG_PREFIX} conta ##{platform_account.id}: " \
        "#{omie_totals.size} título(s) no OMIE entre #{start_date} e #{end_date}, " \
        "#{counters[:total]} repasse(s), #{counters[:com_nf]} com nota fiscal nossa, " \
        "#{counters[:ok]} conferido(s), #{counters[:nao_encontrado]} sem título correspondente, " \
        "#{counters[:divergencias_fechadas]} divergência(s) fechada(s)"
      )
    end

    def fail_run!(error)
      return if run.blank?

      run.update_columns(
        status: "failed",

        finished_at: Time.current,

        metadata: run.metadata.merge(
          "error" => error.message,
          "error_class" => error.class.name
        ),

        updated_at: Time.current
      )
    end
  end
end
