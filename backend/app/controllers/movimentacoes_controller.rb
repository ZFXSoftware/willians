# Briefing 2.7 — transferências entre contas e pagamentos de NF feitos na
# plataforma.
#
# As duas ações escrevem no ERP do cliente, então respeitam a mesma trava do
# resto do sistema: sem OMIE_ALLOW_WRITES elas rodam como SIMULAÇÃO e devolvem
# o que aconteceria, sem tocar no OMIE.
class MovimentacoesController < ApplicationController
  before_action :require_tenant!

  before_action :authorize_write!

  def transferir
    executar do
      Financeiro::TransferenciaEntreContas.new(tenant: current_tenant, **argumentos).call
    end
  end

  def pagar
    executar do
      Financeiro::BaixaDePagamentos.new(tenant: current_tenant, **argumentos).call
    end
  end

  private

  def executar
    resultado = yield

    render json: resultado.merge(status: "ok")
  rescue Financeiro::TransferenciaEntreContas::ConfiguracaoAusente,
         Financeiro::BaixaDePagamentos::ConfiguracaoAusente => e
    # Falta configuração: é acionável pelo usuário, não erro de servidor.
    render json: { status: "error", error: e.message }, status: :unprocessable_content
  rescue ArgumentError, Date::Error => e
    render json: { status: "error", error: e.message }, status: :bad_request
  end

  def argumentos
    {
      start_date: parse_date(params[:start_date]),
      end_date: parse_date(params[:end_date]),
      limite: params[:limite].presence&.to_i,
      # `dry_run` explícito permite simular mesmo com a escrita liberada.
      dry_run: dry_run
    }.compact
  end

  def dry_run
    return if params[:dry_run].nil?

    ActiveModel::Type::Boolean.new.cast(params[:dry_run])
  end
end
