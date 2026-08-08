module Marketplace
  module Shopee
    class Authorization
      def initialize(tenant:, user:, platform_account: nil, client: nil)
        @tenant = tenant

        @user = user

        @platform_account = platform_account

        @client = client || OauthClient.new
      end

      def call
        state = OauthState.issue!(
          platform: Settings::PLATFORM,
          tenant: tenant,
          user: user,
          platform_account: platform_account
        )

        {
          authorization_url: client.authorization_url(
            state: state.state,
            redirect_uri: Settings.redirect_uri
          ),
          state: state.state,
          expires_at: state.expires_at
        }
      end

      private

      attr_reader :tenant,
                  :user,
                  :platform_account,
                  :client
    end
  end
end
