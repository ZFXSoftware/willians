module Painel
  # KPIs do painel, calculados em consultas agregadas por tenant.
  #
  # Não usa o BalanceEngine porque ele é por conta de marketplace: somar conta a
  # conta faria uma rodada de consultas por conta.
  class Resumo
    ULTIMAS = 10

    RECEIVABLE_ABERTO = %w[scheduled available partially_paid].freeze

    def initialize(tenant:)
      @tenant = tenant
    end

    def call
      {
        saldo_virtual: saldo_virtual,
        a_receber: a_receber,
        conciliado: conciliado,
        divergencias: divergencias_valor,
        divergencias_abertas: divergencias_abertas,
        contas_conectadas: contas_conectadas,
        total_contas: tenant.platform_accounts.count,
        ultima_conciliacao: ultima_conciliacao,
        ultimas_movimentacoes: ultimas_movimentacoes
      }
    end

    private

    attr_reader :tenant

    def saldo_virtual
      liquidados["credit"] - liquidados["debit"]
    end

    def liquidados
      @liquidados ||=
        FinancialEntry
          .where(tenant_id: tenant.id, status: :settled)
          .group(:direction)
          .sum(:amount)
          .tap { |h| h.default = BigDecimal("0") }
    end

    def a_receber
      ReceivableUnit
        .where(tenant_id: tenant.id, status: RECEIVABLE_ABERTO)
        .sum(:net_amount)
    end

    def conciliado
      ConciliacaoRegistro
        .where(tenant_id: tenant.id, status: "matched")
        .sum(:valor)
    end

    def divergencias_valor
      DivergenceReport
        .where(tenant_id: tenant.id, status: :open)
        .sum(:difference_amount)
        .abs
    end

    def divergencias_abertas
      DivergenceReport.where(tenant_id: tenant.id, status: :open).count
    end

    def contas_conectadas
      MarketplaceCredential
        .connected
        .where(tenant_id: tenant.id)
        .count
    end

    def ultima_conciliacao
      ConciliationRun
        .where(tenant_id: tenant.id, status: :completed)
        .maximum(:finished_at)
    end

    def ultimas_movimentacoes
      FinancialEntry
        .where(tenant_id: tenant.id)
        .includes(:platform_account)
        .order(occurred_at: :desc)
        .limit(ULTIMAS)
        .map do |entry|
          {
            id: entry.id,
            data: entry.occurred_at,
            descricao: descricao_de(entry),
            plataforma: entry.platform_account&.platform,
            valor: entry.amount,
            direcao: entry.direction,
            tipo: entry.entry_type,
            status: entry.status
          }
        end
    end

    def descricao_de(entry)
      [entry.entry_type&.humanize, entry.external_reference.presence || entry.external_id]
        .compact
        .join(" · ")
    end
  end
end
