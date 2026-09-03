module Marketplace
  # Liga cada lançamento do extrato ao PEDIDO que o originou.
  #
  # É o último elo da corrente. O relatório de liberações identifica cada linha
  # pelo id do PAGAMENTO (a coluna do pedido vem vazia); as notas do Tiny
  # trazem o número do PEDIDO. Sem ninguém ligando um ao outro, o dinheiro e a
  # nota fiscal nunca se encontram — e a conciliação contra o OMIE fica sem
  # chave, mostrando "sem título correspondente" em todas as linhas.
  #
  # O que fecha isso é o próprio Mercado Livre: cada pedido lá lista os
  # pagamentos dele.
  #
  # Só ligar já muda tudo o que vem depois, porque tanto o recebível quanto a
  # nota fiscal se penduram no pedido:
  #
  #   lançamento -> pedido -> NF (Tiny) -> título (OMIE)
  class VinculoDePedidos
    LOG_PREFIX = "[VinculoDePedidos]".freeze

    # Os pedidos são buscados numa janela MAIOR que a do extrato.
    #
    # As duas listas são datadas por coisas diferentes: o extrato pelo dia em
    # que o dinheiro foi LIBERADO, os pedidos pelo dia da VENDA — e o Mercado
    # Pago segura o valor por semanas. Pedindo a mesma janela para os dois, a
    # liberação de hoje de uma venda de 40 dias atrás não encontrava o pedido
    # dela: na primeira sincronização com dado real, 897 lançamentos ficaram
    # órfãos exatamente assim.
    RECUO_DOS_PEDIDOS = 60.days

    def initialize(tenant:, platform_account:, start_date:, end_date:, client: nil)
      @tenant = tenant

      @platform_account = platform_account

      @start_date = start_date.to_date

      @end_date = end_date.to_date

      @client = client
    end

    def call
      resumo = { pedidos: 0, pagamentos: 0, lancamentos_ligados: 0, ja_ligados: 0 }

      pedidos = cliente.orders(start_date: start_date - RECUO_DOS_PEDIDOS, end_date: end_date)

      resumo[:pedidos] = pedidos.size

      pedidos.each do |pedido|
        resumo[:pagamentos] += pedido[:pagamentos].size

        next if pedido[:pagamentos].empty?

        registro = upsert_pedido!(pedido)

        resumo[:lancamentos_ligados] += ligar!(registro, pedido[:pagamentos])
      end

      Rails.logger.info(
        "#{LOG_PREFIX} conta ##{platform_account.id}: #{resumo[:pedidos]} pedido(s), " \
        "#{resumo[:pagamentos]} pagamento(s), #{resumo[:lancamentos_ligados]} lançamento(s) ligados"
      )

      resumo
    end

    private

    attr_reader :tenant, :platform_account, :start_date, :end_date

    def cliente
      @cliente ||= MercadoLivre::OrdersClient.new(
        access_token: Credentials::TokenProvider.new(platform_account: platform_account).access_token,
        seller_id: vendedor
      )
    end

    # O dono do TOKEN, e não o `external_id` da conta.
    #
    # São a mesma coisa quando tudo está certo, mas divergem quando um card foi
    # reconectado com outro login do Mercado Livre. O id gravado na credencial
    # veio junto com o token na autorização, então é impossível ele apontar
    # para outro vendedor — e é essa garantia que o `external_id` não tinha.
    def vendedor
      credencial = platform_account.marketplace_credential

      dono = credencial&.external_user_id.presence

      if dono && dono != platform_account.external_id
        Rails.logger.warn(
          "#{LOG_PREFIX} conta ##{platform_account.id}: o cadastro diz vendedor " \
          "#{platform_account.external_id} e o token é do vendedor #{dono}. " \
          "Usando o dono do token. Reconecte a conta para acertar o cadastro."
        )
      end

      dono || platform_account.external_id
    end

    # O pedido pode já existir vindo da nota do Tiny, que o cria só com o
    # número. Aqui ele ganha conteúdo — comprador, valor, data —, que é o que
    # falta para a tela mostrar algo além do id.
    def upsert_pedido!(pedido)
      registro = Order.find_or_initialize_by(
        tenant_id: tenant.id,
        platform: platform_account.platform,
        external_id: pedido[:external_id]
      )

      registro.assign_attributes(
        platform_account_id: platform_account.id,
        buyer_name: pedido[:comprador].presence || registro.buyer_name,
        total_amount: pedido[:total].presence || registro.total_amount,
        ordered_at: pedido[:criado_em].presence || registro.ordered_at,
        metadata: (registro.metadata || {}).merge(
          "origem" => registro.new_record? ? "mercado_livre" : registro.metadata["origem"],
          "status_ml" => pedido[:status],
          # O pacote a que este pedido pertence, quando a compra levou mais de
          # um item. É por ele que a nota do Tiny encontra esta venda: a NF é
          # emitida para o PACOTE, e o extrato fala do pedido individual.
          "pack_id" => pedido[:pack_id],
          "pagamentos" => pedido[:pagamentos]
        )
      )

      registro.save!

      registro
    end

    # Liga pelo id do pagamento, que o ingestor guarda em `metadata.source_id`
    # de cada lançamento — venda e taxas da mesma linha compartilham o mesmo.
    #
    # `order_id: nil` no filtro para não reescrever vínculo já existente: se um
    # lançamento já aponta para outro pedido, isso é informação, não sujeira.
    def ligar!(registro, pagamentos)
      ligados =
        FinancialEntry
          .where(tenant_id: tenant.id, platform_account_id: platform_account.id, order_id: nil)
          .where("metadata->>'source_id' IN (?)", pagamentos)
          .update_all(
            order_id: registro.id,
            external_reference: registro.external_id,
            updated_at: Time.current
          )

      ligar_recebiveis!(registro)

      ligados
    end

    # O recebível nasce junto com a venda, antes deste vínculo existir, então
    # fica com o pedido em branco. E é por `order_id` que o InvoiceSync pendura
    # a nota fiscal — sem isto, a NF chegaria no lançamento e não no recebível,
    # e é o RECEBÍVEL que o repasse liquida e a conciliação compara.
    #
    # O external_id do recebível é o da venda que o ancorou, o que dá o elo.
    def ligar_recebiveis!(registro)
      vendas = FinancialEntry.where(tenant_id: tenant.id, order_id: registro.id).select(:external_id)

      ReceivableUnit
        .where(tenant_id: tenant.id, platform_account_id: platform_account.id, order_id: nil)
        .where(external_id: vendas)
        .update_all(order_id: registro.id, updated_at: Time.current)
    end
  end
end
