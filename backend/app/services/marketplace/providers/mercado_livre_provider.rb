module Marketplace
  module Providers
    # Traz do Mercado Livre o extrato do dinheiro (relatório de Liberações do
    # Mercado Pago): vendas pelo bruto, cada dedução discriminada e os saques
    # para a conta bancária. É a fonte com `ORDER_ID`, que fecha a corrente
    # pedido -> NF (Tiny) -> título (OMIE).
    #
    # O FATURAMENTO (`BillingEvents`) fica DESLIGADO por padrão, e não por
    # esquecimento: a comissão de venda aparece nas duas fontes — deduzida do
    # pagamento no relatório de liberações e faturada no período pelo billing.
    # Ingerir as duas contaria a mesma taxa duas vezes e corromperia o saldo.
    #
    # O billing continua útil como conferência do documento fiscal do ML e para
    # encargos que não passam por pagamento (Product Ads, mensalidades). Ligue
    # com ML_INGERIR_FATURAMENTO=true quando quiser essa visão — sabendo da
    # sobreposição.
    class MercadoLivreProvider < BaseProvider
      attr_reader :ignorados

      # O relatório de liberações identifica cada linha pelo PAGAMENTO e deixa
      # a coluna do pedido vazia — medido no extrato real do cliente. É por
      # isso que esta é a única plataforma que precisa do passo de vínculo.
      def self.vincula_pedidos? = true

      # Compra com mais de um item vira um "pack" com id próprio, e a nota
      # fiscal é emitida para o PACOTE.
      def self.agrupa_pedidos? = true

      def orders(start_date:, end_date:)
        orders_client.orders(start_date: start_date, end_date: end_date)
      end

      def financial_events(start_date:, end_date:)
        @ignorados = {}

        liberacoes(start_date: start_date, end_date: end_date) +
          faturamento(start_date: start_date, end_date: end_date)
      end

      # O saldo vem das linhas de resumo do MESMO relatório de liberações. O
      # endpoint de saldo do Mercado Pago (/users/$ID/mercadopago_account/
      # balance) existe, mas é liberado sob aprovação — "Public access not
      # allowed" é a resposta comum. Usar o relatório evita essa dependência.
      #
      # ReportPending sobe: "o relatório ainda está sendo gerado" é uma resposta
      # diferente de "não deu para ler o saldo", e quem chama precisa saber qual
      # das duas foi para dizer isso a quem está olhando a tela.
      def account_balance(start_date:, end_date:)
        csv = releases_client.csv_for(start_date: start_date, end_date: end_date)

        saldos = MercadoLivre::ReleaseEvents.new(csv: csv).saldos

        return if saldos.empty?

        {
          available: saldos[:disponivel],
          future: nil,
          total: saldos[:total] || saldos[:disponivel],
          source: "relatorio_de_liberacoes"
        }
      end

      private

      # ReportPending sobe daqui de propósito.
      #
      # Antes era engolido e virava lista vazia, e o resultado chegava na tela
      # como "importação concluída — 0 lançamento(s)". Sucesso com zero é
      # indistinguível de "a conta não vendeu nada no período" — e as duas
      # coisas pedem reações opostas: uma é esperar, a outra é seguir a vida.
      def liberacoes(start_date:, end_date:)
        csv = releases_client.csv_for(start_date: start_date, end_date: end_date)

        leitor = MercadoLivre::ReleaseEvents.new(csv: csv)

        eventos = leitor.call

        @ignorados = leitor.ignorados

        # Toda execução deixa registrado o que o relatório trazia. Sem isso, a
        # única resposta possível para "por que veio zero?" é abrir o CSV na
        # mão — e o CSV não fica guardado em lugar nenhum.
        Rails.logger.info(
          "[MercadoLivre] relatório de #{start_date} a #{end_date}: " \
          "#{leitor.diagnostico[:linhas]} linha(s), #{eventos.size} lançamento(s)"
        )

        eventos
      end

      def faturamento(start_date:, end_date:)
        return [] unless ingerir_faturamento?

        MercadoLivre::BillingEvents
          .new(client: billing_client)
          .call(start_date: start_date, end_date: end_date)
      end

      def ingerir_faturamento?
        %w[true 1].include?(ENV["ML_INGERIR_FATURAMENTO"].to_s.strip.downcase)
      end

      def orders_client
        @orders_client ||= MercadoLivre::OrdersClient.new(
          access_token: access_token,
          seller_id: vendedor
        )
      end

      # O dono do TOKEN, e não o `external_id` da conta.
      #
      # São a mesma coisa quando tudo está certo, mas divergem quando a conta
      # foi reconectada com outro login do Mercado Livre — já aconteceu, e a
      # API respondeu 403 "caller.id does not match". O id gravado na
      # credencial veio junto com o token, então não tem como apontar para
      # outro vendedor; o `external_id` do cadastro tem.
      def vendedor
        dono = account.marketplace_credential&.external_user_id.presence

        if dono && dono != account.external_id
          Rails.logger.warn(
            "[MercadoLivreProvider] conta ##{account.id}: o cadastro diz vendedor " \
            "#{account.external_id} e o token é do vendedor #{dono}. Usando o dono do " \
            "token. Reconecte a conta para acertar o cadastro."
          )
        end

        dono || account.external_id
      end

      def releases_client
        @releases_client ||= MercadoLivre::ReleasesClient.new(access_token: access_token)
      end

      def billing_client
        @billing_client ||= MercadoLivre::BillingClient.new(access_token: access_token)
      end
    end
  end
end
