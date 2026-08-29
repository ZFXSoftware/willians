# O razão inteiro, navegável.
#
# Existia só o "Últimas movimentações" do painel, que mostra as poucas mais
# recentes. Com 2551 lançamentos importados, não havia como responder "e os
# outros?" — nem procurar um pagamento específico, nem ver o que entrou de uma
# plataforma, nem conferir as taxas de um período.
class LancamentosController < ApplicationController
  before_action :require_tenant!

  def index
    resultado = paginated(escopo) { |lancamento| serialize(lancamento) }

    render json: resultado.merge(resumo: resumo)
  rescue ArgumentError => e
    render json: { error: e.message }, status: :bad_request
  end

  private

  def escopo
    scope = FinancialEntry
              .where(tenant_id: current_tenant.id)
              .includes(:order, :platform_account)
              .order(occurred_at: :desc, id: :desc)

    scope = scope.where(entry_type: params[:tipo]) if params[:tipo].present?

    scope = scope.where(status: params[:status]) if params[:status].present?

    scope = scope.where(platform_accounts: { platform: params[:plataforma] })
                 .references(:platform_accounts) if params[:plataforma].present?

    if (de = parse_date(params[:start_date]))
      scope = scope.where(occurred_at: de.beginning_of_day..)
    end

    if (ate = parse_date(params[:end_date]))
      scope = scope.where(occurred_at: ..ate.end_of_day)
    end

    scope = com_busca(scope) if params[:busca].present?

    scope
  end

  # Procura pelo que a pessoa TEM na mão: o número do pedido, o id do pagamento
  # no marketplace, ou a nossa referência. Buscar pelo external_id sozinho não
  # serviria — ele é interno e ninguém o tem anotado em lugar nenhum.
  def com_busca(scope)
    termo = "%#{params[:busca].to_s.strip}%"

    scope
      .left_joins(:order)
      .where(
        "financial_entries.external_id ILIKE :t OR financial_entries.external_reference ILIKE :t " \
        "OR financial_entries.metadata->>'source_id' ILIKE :t OR orders.external_id ILIKE :t",
        t: termo
      )
  end

  def serialize(lancamento)
    {
      id: lancamento.id,
      data: lancamento.occurred_at,
      tipo: lancamento.entry_type,
      direcao: lancamento.direction,
      valor: lancamento.amount,
      status: lancamento.status,
      plataforma: lancamento.platform_account&.platform,
      # O que a pessoa reconhece. O external_id é nosso e não diz nada a
      # ninguém — fica como último recurso, e no title da tela.
      pedido: lancamento.order&.external_id.presence || lancamento.external_reference.presence,
      pagamento: lancamento.metadata.is_a?(Hash) ? lancamento.metadata["source_id"].presence : nil,
      referencia: lancamento.external_id,
      conciliado: lancamento.reconciled
    }
  end

  # Os totais são do FILTRO, e não do razão inteiro: a pergunta que se faz
  # olhando uma lista filtrada é sobre o que está nela.
  def resumo
    base = escopo.except(:includes, :order)

    {
      total: base.count,
      por_tipo: base.group(:entry_type).count,
      creditos: base.where(direction: :credit).sum(:amount),
      debitos: base.where(direction: :debit).sum(:amount)
    }
  end
end
