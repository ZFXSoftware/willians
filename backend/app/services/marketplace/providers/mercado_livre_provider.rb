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

      def financial_events(start_date:, end_date:)
        @ignorados = {}

        liberacoes(start_date: start_date, end_date: end_date) +
          faturamento(start_date: start_date, end_date: end_date)
      end

      private

      def liberacoes(start_date:, end_date:)
        csv = releases_client.csv_for(start_date: start_date, end_date: end_date)

        leitor = MercadoLivre::ReleaseEvents.new(csv: csv)

        eventos = leitor.call

        @ignorados = leitor.ignorados

        eventos
      rescue MercadoLivre::ReleasesClient::ReportPending => e
        # Geração assíncrona: não é falha, é "ainda não". A próxima execução
        # encontra o arquivo pronto, e nada foi perdido.
        Rails.logger.info "[MercadoLivre] #{e.message}"

        []
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

      def releases_client
        @releases_client ||= MercadoLivre::ReleasesClient.new(access_token: access_token)
      end

      def billing_client
        @billing_client ||= MercadoLivre::BillingClient.new(access_token: access_token)
      end
    end
  end
end
