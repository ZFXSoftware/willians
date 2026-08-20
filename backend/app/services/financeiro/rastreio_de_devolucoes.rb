module Financeiro
  # Briefing 2.8 — Devoluções e Contestações.
  #
  # Percorre os lançamentos de dinheiro voltando (estorno, disputa, chargeback)
  # e costura cada um à venda de origem: pedido, NF de venda e, quando já
  # emitida, a NF de devolução. O estado avança sozinho conforme as peças
  # aparecem, e o que não tem origem fica visível em vez de sumir.
  class RastreioDeDevolucoes
    TIPOS = {
      "refund" => :devolucao,
      "dispute" => :disputa,
      "chargeback" => :chargeback
    }.freeze

    def initialize(tenant:, start_date: nil, end_date: nil)
      @tenant = tenant

      @end_date = (end_date || Date.current).to_date

      @start_date = (start_date || @end_date - 90).to_date
    end

    def call
      Current.with_tenant(tenant) do
        resumo = Hash.new(0)

        lancamentos.find_each do |lancamento|
          devolucao = registrar(lancamento)

          resumo[devolucao.status.to_sym] += 1
        end

        resumo[:total] = resumo.values.sum

        { resumo: resumo.to_h }
      end
    end

    private

    attr_reader :tenant,
                :start_date,
                :end_date

    def lancamentos
      FinancialEntry
        .where(tenant_id: tenant.id, entry_type: TIPOS.keys)
        .where(occurred_at: start_date.beginning_of_day..end_date.end_of_day)
        .includes(:order)
    end

    def registrar(lancamento)
      devolucao = Devolucao.find_or_initialize_by(
        tenant_id: tenant.id,
        external_id: lancamento.external_id
      )

      nota_de_venda = nota_de_venda_para(lancamento)

      nota_de_devolucao = nota_de_devolucao_para(lancamento)

      devolucao.assign_attributes(
        platform_account_id: lancamento.platform_account_id,
        order_id: lancamento.order_id,
        invoice_id: nota_de_venda&.id,
        return_invoice_id: nota_de_devolucao&.id,
        platform: lancamento.platform_account&.platform,
        kind: TIPOS.fetch(lancamento.entry_type.to_s, :devolucao),
        amount: lancamento.amount,
        opened_at: devolucao.opened_at || lancamento.occurred_at,
        status: situacao(lancamento, nota_de_venda, nota_de_devolucao),
        metadata: devolucao.metadata.merge(
          "financial_entry_id" => lancamento.id,
          "entry_type" => lancamento.entry_type,
          "atualizado_em" => Time.current
        )
      )

      devolucao.resolved_at ||= Time.current if devolucao.status == "concluida"

      devolucao.save!

      devolucao
    end

    # A ordem importa: cada estado só é alcançado quando o anterior já vale.
    def situacao(lancamento, nota_de_venda, nota_de_devolucao)
      return :sem_origem if lancamento.order_id.blank?

      return :aberta if nota_de_venda.blank?

      return :concluida if nota_de_devolucao.present?

      :aguardando_nota
    end

    # A NF da venda que está sendo devolvida.
    def nota_de_venda_para(lancamento)
      return if lancamento.order_id.blank?

      Invoice
        .where(tenant_id: tenant.id, order_id: lancamento.order_id)
        .where(operation_type: [nil, "sale"])
        .order(:issued_at)
        .first
    end

    # A NF de devolução é a nota de ENTRADA do mesmo pedido.
    def nota_de_devolucao_para(lancamento)
      return if lancamento.order_id.blank?

      Invoice
        .where(tenant_id: tenant.id, order_id: lancamento.order_id, operation_type: "refund")
        .order(:issued_at)
        .first
    end
  end
end
