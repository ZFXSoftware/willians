module Marketplace
  # Renova as credenciais que estão perto de vencer.
  #
  # O access_token do Mercado Livre dura 6 horas; rodando de hora em hora, uma
  # falha isolada ainda tem várias tentativas antes de expirar de fato.
  class RefreshCredentialsJob < ApplicationJob
    queue_as :default

    def perform
      renovadas = 0

      falhas = 0

      MarketplaceCredential.refreshable.includes(:platform_account).find_each do |credential|
        Credentials::TokenProvider
          .new(platform_account: credential.platform_account)
          .refresh!(credential)

        renovadas += 1
      rescue Credentials::TokenProvider::NeedsReauthorization => e
        falhas += 1

        Rails.logger.warn "[RefreshCredentials] conta ##{credential.platform_account_id} precisa reautorizar: #{e.message}"
      rescue StandardError => e
        falhas += 1

        Rails.logger.error "[RefreshCredentials] conta ##{credential.platform_account_id}: #{e.class} #{e.message}"
      end

      Rails.logger.info "[RefreshCredentials] #{renovadas} renovada(s), #{falhas} falha(s)"

      { refreshed: renovadas, failed: falhas }
    end
  end
end
