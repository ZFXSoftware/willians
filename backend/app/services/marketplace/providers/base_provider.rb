module Marketplace
  module Providers
    class BaseProvider
      def initialize(account:)
        @account = account
      end

      # => Array de hashes normalizados (ver FinancialEntryNormalizer)
      def financial_events(start_date:, end_date:)
        raise NotImplementedError, "#{self.class} precisa implementar #financial_events"
      end

      # Devoluções e disputas registradas na plataforma (briefing 2.8). Nem
      # toda plataforma expõe; o padrão é dizer que não sabe.
      def returns(start_date:, end_date:)
        raise NotImplementedError, "#{self.class} não informa devoluções"
      end

      # Saldo que a PLATAFORMA declara ter, para o espelho do briefing 2.4.
      # Nem toda plataforma expõe isso, então o padrão é dizer que não sabe em
      # vez de devolver zero — zero seria lido como "conferido e bate".
      def account_balance(start_date:, end_date:)
        raise NotImplementedError, "#{self.class} não informa saldo da conta"
      end

      # O extrato desta plataforma traz o número do PEDIDO em cada linha?
      #
      # Quase sempre sim, e aí a ingestão já liga sozinha: Shopee traz o
      # `order_sn` no escrow, Amazon traz o pedido no evento financeiro.
      #
      # O Mercado Livre é a exceção: o relatório de liberações identifica cada
      # linha pelo id do PAGAMENTO e deixa a coluna do pedido vazia. Sem alguém
      # perguntar à API de pedidos quais pagamentos pertencem a qual pedido, o
      # dinheiro e a nota fiscal nunca se encontram.
      #
      # Isto era um `return unless conta.mercado_livre?` escondido dentro do
      # serviço de sincronização. Como condição enterrada, ela silenciava: ao
      # conectar a Shopee, os lançamentos entrariam e nada seria vinculado, sem
      # nenhum sinal. Como contrato, cada provider responde por si — e quem
      # disser que precisa é obrigado a implementar `orders`.
      def self.vincula_pedidos? = false

      # Os pedidos do período, com os identificadores que aparecem no extrato.
      #
      # => [{ external_id:, pagamentos: [], agrupador:, status:, total:,
      #       criado_em:, comprador: }]
      #
      # `agrupador` é o id sob o qual a nota fiscal é emitida quando a
      # plataforma junta pedidos — o `pack_id` do Mercado Livre. Nulo quando
      # não há agrupamento.
      def orders(start_date:, end_date:)
        raise NotImplementedError,
              "#{self.class} declarou que precisa de vínculo de pedidos mas não implementa #orders"
      end

      # A plataforma junta vários pedidos sob um id para efeito fiscal?
      #
      # Só o Mercado Livre, por enquanto. Quem agrupa precisa que o vínculo da
      # nota saiba disso, senão a NF do pacote nunca encontra as vendas.
      def self.agrupa_pedidos? = false

      # Credenciais vivem em marketplace_credentials, com os tokens cifrados.
      def self.configured?(account)
        MarketplaceCredential
          .connected
          .where(platform_account_id: account.id)
          .where.not(access_token: nil)
          .exists?
      end

      private

      attr_reader :account

      # Sempre passa pelo TokenProvider: ele renova se estiver perto de vencer.
      def access_token
        Marketplace::Credentials::TokenProvider
          .new(platform_account: account)
          .access_token
      end

      def normalize(source, payload)
        Marketplace::Normalizers::FinancialEntryNormalizer
          .new(
            source: source,
            payload: payload
          )
          .call
      end
    end
  end
end
