module Marketplace
  module Providers
    class BaseProvider
      def initialize(account:)
        @account = account
      end

      private

      attr_reader :account
    end
  end
end