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

      # Saldo que a PLATAFORMA declara ter, para o espelho do briefing 2.4.
      # Nem toda plataforma expõe isso, então o padrão é dizer que não sabe em
      # vez de devolver zero — zero seria lido como "conferido e bate".
      def account_balance(start_date:, end_date:)
        raise NotImplementedError, "#{self.class} não informa saldo da conta"
      end

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
