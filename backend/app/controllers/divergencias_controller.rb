class DivergenciasController < ApplicationController
  before_action :require_tenant!

  def index
    resultado = paginated(escopo) { |divergencia| serialize(divergencia) }

    render json: resultado.merge(resumo: resumo)
  rescue ArgumentError => e
    render json: { error: e.message }, status: :bad_request
  end

  private

  def escopo
    scope = DivergenceReport
              .where(tenant_id: current_tenant.id)
              .includes(financial_entry: :platform_account)
              .order(created_at: :desc)

    scope = scope.where(status: params[:status]) if params[:status].present?

    scope = scope.where(divergence_type: params[:tipo]) if params[:tipo].present?

    if (de = parse_date(params[:start_date]))
      scope = scope.where(created_at: de.beginning_of_day..)
    end

    if (ate = parse_date(params[:end_date]))
      scope = scope.where(created_at: ..ate.end_of_day)
    end

    scope
  end

  def serialize(divergencia)
    entry = divergencia.financial_entry

    {
      id: divergencia.id,
      tipo: divergencia.divergence_type,
      status: divergencia.status,
      valor_esperado: divergencia.expected_amount,
      valor_recebido: divergencia.received_amount,
      diferenca: divergencia.difference_amount,
      data: divergencia.created_at,
      resolvida_em: divergencia.resolved_at,
      observacoes: divergencia.resolution_notes,
      referencia: entry&.external_id,
      plataforma: entry&.platform_account&.platform,
      metadata: divergencia.metadata
    }
  end

  def resumo
    base = DivergenceReport.where(tenant_id: current_tenant.id)

    {
      por_status: base.group(:status).count,
      por_tipo: base.group(:divergence_type).count,
      valor_em_disputa: base.where(status: :open).sum(:difference_amount).abs,
      resolvidas_no_mes: base.where(status: :resolved)
                             .where(resolved_at: Time.current.beginning_of_month..)
                             .count
    }
  end
end
