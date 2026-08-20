# Briefing 2.8 — devoluções e disputas rastreáveis.
class DevolucoesController < ApplicationController
  before_action :require_tenant!

  before_action :authorize_write!, only: :rastrear

  def index
    escopo = Devolucao
               .where(tenant_id: current_tenant.id)
               .includes(:order, :invoice, :return_invoice, :platform_account)
               .order(opened_at: :desc, id: :desc)

    escopo = escopo.where(status: params[:status]) if params[:status].present?

    render json: paginated(escopo) { |devolucao| serialize(devolucao) }.merge(resumo: resumo)
  end

  def rastrear
    resultado = Financeiro::RastreioDeDevolucoes.new(
      tenant: current_tenant,
      start_date: parse_date(params[:start_date]),
      end_date: parse_date(params[:end_date])
    ).call

    render json: resultado.merge(status: "ok")
  rescue ArgumentError, Date::Error => e
    render json: { status: "error", error: e.message }, status: :bad_request
  end

  private

  def serialize(devolucao)
    {
      id: devolucao.id,
      external_id: devolucao.external_id,
      tipo: devolucao.kind,
      status: devolucao.status,
      plataforma: devolucao.platform,
      valor: devolucao.amount,
      aberta_em: devolucao.opened_at,
      concluida_em: devolucao.resolved_at,
      pedido: devolucao.order && {
        id: devolucao.order_id,
        external_id: devolucao.order.external_id
      },
      nota_de_venda: nota(devolucao.invoice),
      nota_de_devolucao: nota(devolucao.return_invoice),
      # O que falta para o ciclo fechar, em uma frase.
      pendencia: pendencia(devolucao)
    }
  end

  def nota(invoice)
    return if invoice.blank?

    { id: invoice.id, numero: invoice.number, emitida_em: invoice.issued_at,
      valor: invoice.total_amount, chave: invoice.access_key }
  end

  def pendencia(devolucao)
    case devolucao.status
    when "sem_origem"
      "Não foi possível identificar o pedido de origem deste estorno."
    when "aberta"
      "Pedido identificado, mas a nota fiscal da venda ainda não foi importada."
    when "aguardando_nota"
      "Falta emitir (ou importar) a nota fiscal de devolução."
    end
  end

  def resumo
    contagem = Devolucao.where(tenant_id: current_tenant.id).group(:status).count

    {
      total: contagem.values.sum,
      em_aberto: contagem.except("concluida").values.sum,
      por_status: contagem
    }
  end
end
