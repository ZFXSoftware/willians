# Briefing 2.4 — o espelho da conta virtual.
#
# GET  /saldos       último snapshot de cada conta, com os dois lados
# POST /saldos/conferir  roda a conferência agora
class SaldosController < ApplicationController
  before_action :require_tenant!

  before_action :authorize_write!, only: :conferir

  def index
    render json: {
      items: contas.map { |conta| serialize(conta, ultimos[conta.id]) },
      resumo: resumo
    }
  end

  def conferir
    resultado = Financeiro::ConciliacaoDeSaldo.new(
      tenant: current_tenant,
      platform_account: conta_solicitada,
      start_date: parse_date(params[:start_date]),
      end_date: parse_date(params[:end_date])
    ).call

    render json: resultado.merge(status: "ok")
  rescue ArgumentError, Date::Error => e
    render json: { status: "error", error: e.message }, status: :bad_request
  end

  private

  def contas
    @contas ||= current_tenant.platform_accounts.where(status: :active).order(:id).to_a
  end

  def conta_solicitada
    return if params[:platform_account_id].blank?

    current_tenant.platform_accounts.find(params[:platform_account_id])
  end

  # Um snapshot por conta por dia; queremos o mais recente de cada uma.
  def ultimos
    @ultimos ||=
      PlatformBalanceSnapshot
        .where(platform_account_id: contas.map(&:id))
        .order(:platform_account_id, snapshot_date: :desc)
        .group_by(&:platform_account_id)
        .transform_values(&:first)
  end

  def serialize(conta, snapshot)
    {
      platform_account_id: conta.id,
      nome: conta.name,
      plataforma: conta.platform,
      conferido_em: snapshot&.snapshot_date,
      origem_do_saldo: snapshot&.platform_source,
      saldo_plataforma: {
        disponivel: snapshot&.platform_available_balance,
        futuro: snapshot&.platform_future_balance,
        total: snapshot&.platform_total_balance
      },
      saldo_interno: {
        disponivel: snapshot&.available_balance,
        futuro: snapshot&.future_balance,
        bloqueado: snapshot&.blocked_balance
      },
      diferenca: snapshot&.difference_amount,
      situacao: situacao(snapshot)
    }
  end

  # Sem snapshot não é "confere": é que ninguém conferiu ainda.
  def situacao(snapshot)
    return "nao_conferido" if snapshot.blank?

    return "divergente" if snapshot.difference_amount.to_d.abs > Financeiro::ConciliacaoDeSaldo::TOLERANCIA

    "confere"
  end

  def resumo
    situacoes = contas.map { |conta| situacao(ultimos[conta.id]) }

    {
      total: contas.size,
      confere: situacoes.count("confere"),
      divergente: situacoes.count("divergente"),
      nao_conferido: situacoes.count("nao_conferido")
    }
  end
end
