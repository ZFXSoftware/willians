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
        .includes(:platform_account, :order)
        .order(occurred_at: :desc)
        .limit(ULTIMAS)
        .map do |entry|
          {
            id: entry.id,
            data: entry.occurred_at,
            # Em pedaços, e não numa frase pronta: o texto que a pessoa lê é
            # decisão de tela, e o dicionário de rótulos em português já vive
            # lá. Aqui ficam os fatos.
            plataforma: entry.platform_account&.platform,
            valor: entry.amount,
            direcao: entry.direction,
            tipo: entry.entry_type,
            pedido: pedido_de(entry),
            pagamento: pagamento_de(entry),
            referencia: entry.external_id,
            status: entry.status
          }
        end
    end

    # O número do pedido é o que a pessoa reconhece — é por ele que ela acha a
    # venda no Mercado Livre e a nota no Tiny. O external_id é nosso, interno,
    # e não diz nada a ninguém.
    def pedido_de(entry)
      entry.order&.external_id.presence || entry.external_reference.presence
    end

    # O relatório de liberações do Mercado Livre não traz o número do pedido:
    # PURCHASE_ID vem vazio em todas as linhas, e o único identificador é o
    # SOURCE_ID, o id do pagamento no Mercado Pago. Não é o pedido, mas é por
    # ele que a pessoa acha o lançamento no extrato — melhor do que "sem
    # pedido associado" e ponto final.
    def pagamento_de(entry)
      entry.metadata.is_a?(Hash) ? entry.metadata["source_id"].presence : nil
    end
  end
end
