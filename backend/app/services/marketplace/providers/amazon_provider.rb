module Marketplace
  module Providers
    # Único dos três marketplaces com leitura financeira implementada de fato: a
    # Amazon publica o modelo da SP-API abertamente, então os caminhos, os
    # parâmetros e a forma dos eventos puderam ser conferidos.
    #
    # Cuidado conhecido da própria documentação: pedidos das últimas 48 horas
    # podem ainda não aparecer nos eventos financeiros. Como a ingestão é
    # idempotente, o que faltar entra numa execução seguinte.
    class AmazonProvider < BaseProvider
      def financial_events(start_date:, end_date:)
        eventos = Amazon::FinancialEvents
                    .new(client: client)
                    .call(start_date: start_date, end_date: end_date)

        # Os saques vêm dos GRUPOS, não dos eventos: um grupo fechado com
        # FundTransferDate é o dinheiro do ciclo indo para o banco.
        eventos + grupos(start_date: start_date, end_date: end_date).saques
      end

      # Briefing 2.4. A Amazon não tem carteira com saldo disponível: o que
      # existe é o ciclo aberto acumulando o que ela tem a pagar. Reportar isso
      # como "disponível" seria mentira, então vai como FUTURO — e a
      # conciliação compara contra o nosso futuro, não contra o disponível.
      def account_balance(start_date:, end_date:)
        aberto = grupos(start_date: start_date, end_date: end_date).aberto

        a_receber = Amazon::EventGroups.a_receber(aberto)

        return if a_receber.blank?

        {
          available: nil,
          future: a_receber[:valor],
          total: a_receber[:valor],
          source: "ciclo_aberto_amazon"
        }
      end

      private

      # Uma leitura só por execução: os grupos servem ao saque e ao saldo.
      def grupos(start_date:, end_date:)
        @grupos ||= Amazon::EventGroups.new(client: client)
                                       .call(start_date: start_date, end_date: end_date)
      end

      def client
        @client ||= Amazon::Client.new(access_token: access_token)
      end
    end
  end
end
