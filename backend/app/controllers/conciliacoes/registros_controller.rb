module Conciliacoes
  class RegistrosController < ApplicationController
    before_action :require_tenant!

    def index
      resultado = paginated(escopo) { |registro| serialize(registro) }

      render json: resultado.merge(resumo: resumo)
    rescue ArgumentError => e
      render json: { error: e.message }, status: :bad_request
    end

    private

    def escopo
      scope = ConciliacaoRegistro
                .where(tenant_id: current_tenant.id)
                .includes(:conciliation_run, :payout_batch)
                .order(conciliated_at: :desc, id: :desc)

      scope = scope.where(status: params[:status]) if params[:status].present?

      scope = scope.where(conciliation_run: { platform: params[:plataforma] }) if params[:plataforma].present?

      if (de = parse_date(params[:start_date]))
        scope = scope.where(conciliated_at: de.beginning_of_day..)
      end

      if (ate = parse_date(params[:end_date]))
        scope = scope.where(conciliated_at: ..ate.end_of_day)
      end

      if params[:busca].present?
        termo = "%#{params[:busca].to_s.strip}%"

        scope = scope.where("referencia ILIKE :t OR descricao ILIKE :t OR observacao ILIKE :t", t: termo)
      end

      scope
    end

    def serialize(registro)
      metadata = registro.conciliation_metadata || {}

      {
        id: registro.id,
        status: registro.status,
        match_type: registro.match_type,
        confianca: registro.confidence_score,
        referencia: registro.referencia,
        plataforma: registro.conciliation_run&.platform,
        # `valor` é o que o marketplace repassou; o esperado vem do OMIE.
        valor_recebido: registro.valor,
        valor_esperado: metadata["valor_omie"],
        diferenca: registro.diferenca,
        data: registro.conciliated_at,
        observacao: registro.observacao,
        payout_batch_id: registro.payout_batch_id,
        financial_entry_id: registro.financial_entry_id
      }
    end

    def resumo
      base = ConciliacaoRegistro.where(tenant_id: current_tenant.id)

      por_status = base.group(:status).count

      {
        por_status: por_status,
        total_conciliado: base.where(status: "matched").sum(:valor),
        divergencias_abertas: DivergenceReport.where(tenant_id: current_tenant.id, status: :open).count,
        ultima_execucao: ConciliationRun.where(tenant_id: current_tenant.id).maximum(:finished_at),
        execucoes_hoje: ConciliationRun
                          .where(tenant_id: current_tenant.id)
                          .where(started_at: Time.current.beginning_of_day..)
                          .count
      }
    end
  end
end
