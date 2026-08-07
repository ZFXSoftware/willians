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

    def initialize(
      tenant:,
      platform_account:,
      start_date:,
      end_date:,
      omie_client: nil
    )
      @tenant = tenant

      @platform_account = platform_account

      @start_date = start_date.to_date

      @end_date = end_date.to_date

      @omie_client = omie_client || default_client

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

    def fetch_omie_totals
      Omie::Readers::ReceivableTotals
        .new(client: omie_client)
        .call(
          start_date: start_date - EMISSION_LOOKBACK_DAYS,
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

        registros << registro_row(payout, resultado)

        divergencia = divergencia_row(payout, resultado)

        divergencias << divergencia if divergencia

        if registros.size >= BATCH_SIZE
          flush!(registros, divergencias)
        end
      end

      flush!(registros, divergencias)
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
      encontradas =
        referencias_for(payout).select { |ref| omie_totals.key?(ref) }

      return if encontradas.empty?

      encontradas.sum(BigDecimal("0")) { |ref| omie_totals[ref] }
    end

    # Um repasse é conciliado pelas referências dos recebíveis que ele liquidou.
    # Quando o repasse ainda não tem recebível alocado, cai na própria referência
    # externa do repasse.
    def referencias_for(payout)
      refs =
        payout
          .financial_entry_allocations
          .filter_map { |allocation| allocation.receivable_unit&.external_id }
          .uniq

      refs.presence || [payout.external_id].compact
    end

    def payouts
      PayoutBatch
        .where(
          tenant: tenant,
          platform_account: platform_account
        )
        .where(paid_at: start_date.beginning_of_day..end_date.end_of_day)
        .includes(financial_entry_allocations: :receivable_unit)
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

        observacao: resultado.mensagem,

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

      chave = [payout.financial_entry_id, tipo]

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
          "nao_encontrados" => counters[:nao_encontrado]
        )
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
