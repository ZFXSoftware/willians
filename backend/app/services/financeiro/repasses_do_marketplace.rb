module Financeiro
  # Transforma os repasses que vieram no extrato do marketplace em lotes de
  # repasse (PayoutBatch), liquidando os recebíveis que eles pagaram.
  #
  # Este era o elo que faltava para a tela de conciliação.
  #
  # A cadeia é: o marketplace entrega os lançamentos -> a venda vira recebível
  # -> o repasse liquida os recebíveis num LOTE -> a conciliação compara esse
  # lote com os títulos do OMIE. O ConciliacaoEngine itera sobre PayoutBatch,
  # e PayoutBatch só nascia do PayoutEngine, que ninguém chamava. Sem lote não
  # há registro de conciliação, e a tela ficava vazia com o razão cheio.
  #
  # Mesmo padrão do MarketplaceIngestor: cada repasse é isolado, para que um
  # problema num não impeça os outros de fechar.
  class RepassesDoMarketplace
    LOG_PREFIX = "[Repasses]".freeze

    def initialize(tenant:, platform_account:, start_date: nil, end_date: nil)
      @tenant = tenant

      @platform_account = platform_account

      @start_date = start_date

      @end_date = end_date
    end

    def call
      resumo = { repasses: 0, criados: 0, falhas: 0 }

      pendentes.find_each do |lancamento|
        resumo[:repasses] += 1

        lote = processar(lancamento)

        resumo[:criados] += 1 if lote
      rescue StandardError => e
        resumo[:falhas] += 1

        Rails.logger.error(
          "#{LOG_PREFIX} lançamento ##{lancamento.id} não virou lote: #{e.class} #{e.message}"
        )
      end

      Rails.logger.info(
        "#{LOG_PREFIX} conta ##{platform_account.id}: #{resumo[:repasses]} repasse(s), " \
        "#{resumo[:criados]} lote(s) novo(s), #{resumo[:falhas]} falha(s)"
      )

      resumo
    end

    private

    attr_reader :tenant,
                :platform_account,
                :start_date,
                :end_date

    def processar(lancamento)
      PayoutEngine.new(
        tenant: tenant,
        platform_account: platform_account,
        payout_reference: lancamento.external_id,
        paid_at: lancamento.occurred_at,
        # O lançamento JÁ existe: é a linha do extrato. Passá-lo evita que o
        # engine crie um segundo e conte a mesma saída de dinheiro duas vezes.
        settlement_entry: lancamento
      ).call
    end

    # Repasses que ainda não viraram lote. A checagem é por `external_id` em
    # payout_batches, e não por uma coluna no lançamento, porque é ela que o
    # PayoutEngine usa para ser idempotente.
    def pendentes
      escopo = FinancialEntry
                 .where(
                   tenant_id: tenant.id,
                   platform_account_id: platform_account.id,
                   entry_type: :settlement
                 )
                 .where.not(external_id: lotes_existentes)
                 .order(:occurred_at)

      escopo = escopo.where(occurred_at: janela) if janela

      escopo
    end

    def lotes_existentes
      PayoutBatch.where(tenant_id: tenant.id).select(:external_id)
    end

    def janela
      return if start_date.blank? || end_date.blank?

      start_date.to_date.beginning_of_day..end_date.to_date.end_of_day
    end
  end
end
