class DivergenciasController < ApplicationController
  before_action :require_tenant!

  before_action :authorize_write!, only: %i[contestar resolver]

  before_action :carregar, only: %i[contestacao contestar resolver]

  def index
    resultado = paginated(escopo) { |divergencia| serialize(divergencia) }

    render json: resultado.merge(resumo: resumo)
  rescue ArgumentError => e
    render json: { error: e.message }, status: :bad_request
  end

  # Briefing 2.5: os dados prontos para levar à central da plataforma.
  def contestacao
    render json: Divergencias::Contestacao.new(@divergencia).call
  end

  # Registra que a contestação foi aberta, com o protocolo devolvido pela
  # plataforma — é por ele que se acompanha o caso depois.
  def contestar
    @divergencia.update!(
      status: :analyzing,
      metadata: @divergencia.metadata.merge(
        "contestacao" => {
          "protocolo" => params[:protocolo].presence,
          "observacao" => params[:observacao].presence,
          "aberta_em" => Time.current,
          "por" => current_user&.email
        }.compact
      )
    )

    render json: serialize(@divergencia.reload)
  end

  # Fecha o caso depois do ajuste. O briefing pede que o ajuste financeiro se
  # reflita no OMIE; quando ele chega como lançamento, a conciliação o trata
  # como qualquer outro valor — aqui fica o registro de que o caso terminou.
  def resolver
    @divergencia.update!(
      status: :resolved,
      resolved_at: Time.current,
      resolution_notes: params[:observacao].presence || "Resolvida manualmente."
    )

    render json: serialize(@divergencia.reload)
  end

  private

  def carregar
    @divergencia = DivergenceReport.find_by(id: params[:id], tenant_id: current_tenant.id)

    render json: { error: "Divergência não encontrada" }, status: :not_found if @divergencia.blank?
  end

  def escopo
    scope = DivergenceReport
              .where(tenant_id: current_tenant.id)
              .includes(financial_entry: %i[platform_account order invoice])
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
      pedido: entry&.order&.external_id,
      nota_fiscal: entry&.invoice&.number,
      contestacao: divergencia.metadata["contestacao"],
      metadata: divergencia.metadata
    }
  end

  def resumo
    base = DivergenceReport.where(tenant_id: current_tenant.id)

    {
      por_status: base.group(:status).count,
      por_tipo: base.group(:divergence_type).count,
      # Só o que foi de fato COMPARADO.
      #
      # Em "título não encontrado" não houve comparação: a diferença gravada é
      # o repasse inteiro, porque o outro lado é nulo. Somar isso como "valor
      # em disputa" inflava o número com dinheiro que ninguém está disputando —
      # e é justamente o caso mais comum enquanto o OMIE está sendo populado.
      valor_em_disputa: base.where(status: :open)
                            .where.not(expected_amount: nil)
                            .sum(:difference_amount).abs,
      # Contados à parte: não são disputa, são conciliação que não aconteceu.
      sem_comparacao: base.where(status: :open, expected_amount: nil).count,
      resolvidas_no_mes: base.where(status: :resolved)
                             .where(resolved_at: Time.current.beginning_of_month..)
                             .count
    }
  end
end
