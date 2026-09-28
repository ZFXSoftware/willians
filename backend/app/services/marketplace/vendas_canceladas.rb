module Marketplace
  # Pedido cancelado E estornado no marketplace não é venda, e o razão tem que saber
  # disso sozinho.
  #
  # Em 2026-09-28, 38 recebíveis de pedidos cancelados estavam contando como receita
  # dentro de repasses — R$ 6.204,72. Eu descobri porque o cliente perguntou como um
  # pedido podia estar num repasse sem nota fiscal, perguntei ao Mercado Livre pedido por
  # pedido com uma tarefa escrita na hora, e marquei à mão.
  #
  # Nada em `app/` escrevia a marca. O próximo cancelamento entraria como receita de
  # novo, e a resposta para "não vamos ter que fazer sempre esse processo?" seria "vamos".
  #
  # O relatório de liberações NÃO serve para isto: das 38, só UMA tem linha `refund`, e
  # essas linhas devolvem a comissão (`GROSS_AMOUNT` zero, `MP_FEE_AMOUNT` 25,55), não a
  # venda. Quem sabe é a API de pedidos, e a ingestão já fala com ela a cada volta —
  # `VinculoDePedidos` relê os pedidos com 60 dias de recuo e reescreve o estado.
  #
  # NÃO apaga, e não desmarca: marca, com o motivo e o estado que o marketplace informou.
  class VendasCanceladas
    LOG_PREFIX = "[VendasCanceladas]".freeze

    # Estornado, contestado ou cancelado. `approved` fica de fora de propósito: pedido
    # cancelado cujo pagamento continua aprovado é dinheiro que ficou com o cliente, e
    # essa venda VALE — são os 4 pedidos que sobraram como venda real sem nota.
    ESTORNADO = /refunded|charged_back|cancelled/

    def initialize(tenant:, platform_account:)
      @tenant = tenant

      @platform_account = platform_account
    end

    def call
      alvos = recebiveis_de_cancelados

      return vazio if alvos.empty?

      lotes = Set.new

      ReceivableUnit.transaction do
        alvos.each do |unidade|
          marcar!(unidade)

          lotes.merge(lotes_de(unidade))
        end
      end

      # Marcar sem recalcular não conserta nada: o bruto do repasse continuaria somando
      # o que a conciliação passou a ignorar.
      recalculados = PayoutBatch.where(id: lotes.to_a).count { |lote| Financeiro::TotaisDoRepasse.gravar!(lote) }

      Rails.logger.info(
        "#{LOG_PREFIX} conta ##{platform_account.id}: #{alvos.size} recebível(is) de pedido " \
        "cancelado marcado(s), #{recalculados} repasse(s) recalculado(s)"
      )

      { marcados: alvos.size, repasses_recalculados: recalculados }
    end

    private

    attr_reader :tenant, :platform_account

    def vazio = { marcados: 0, repasses_recalculados: 0 }

    # Os pedidos cujo ESTADO GRAVADO diz cancelado com estorno. O estado vem da
    # ingestão, que fala com a API; aqui não há requisição nenhuma.
    def recebiveis_de_cancelados
      pedidos = Order
                  .where(tenant_id: tenant.id, platform_account_id: platform_account.id)
                  .where("metadata->>'status_ml' = 'cancelled'")
                  .pluck(:id, :metadata)

      ids = pedidos.filter_map do |id, metadata|
        situacoes = Array(metadata.to_h["situacoes_de_pagamento"])

        # Sem o estado do pagamento não há o que afirmar: pedido gravado antes desta
        # captura fica de fora em vez de ser marcado por meia evidência.
        next if situacoes.empty?

        id if situacoes.any? { |situacao| situacao.to_s.match?(ESTORNADO) }
      end

      return [] if ids.empty?

      ReceivableUnit
        .where(tenant_id: tenant.id, order_id: ids)
        .vendas_reais
        .to_a
    end

    def marcar!(unidade)
      situacoes = Array(unidade.order&.metadata.to_h["situacoes_de_pagamento"]).join("/")

      unidade.update!(metadata: (unidade.metadata || {}).merge(
        ReceivableUnit::MARCA_NAO_E_VENDA => {
          "descricao" => "pedido cancelado no marketplace",
          "motivo" => "pedido cancelled e pagamento #{situacoes}: não houve venda",
          "origem" => "ingestao",
          "marcado_em" => Time.current
        }
      ))
    end

    def lotes_de(unidade)
      FinancialEntryAllocation
        .where(tenant_id: tenant.id, receivable_unit_id: unidade.id)
        .where.not(payout_batch_id: nil)
        .distinct
        .pluck(:payout_batch_id)
    end
  end
end
