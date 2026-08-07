module Integracoes
  class MercadoLivreController < ApplicationController
    # O callback é público por natureza: quem chega nele é o navegador
    # redirecionado pelo Mercado Livre, sem a nossa sessão. A identidade vem do
    # `state`, que é de uso único.
    allow_unauthenticated :callback

    before_action :require_tenant!, only: :autorizar

    before_action :authorize_write!, only: [:autorizar, :desconectar]

    def autorizar
      resultado = Marketplace::MercadoLivre::Authorization.new(
        tenant: current_tenant,
        user: current_user,
        platform_account: optional_platform_account
      ).call

      render json: resultado
    rescue Marketplace::MercadoLivre::OauthClient::ConfigError,
           Marketplace::MercadoLivre::Settings::MissingPublicUrl => e
      render json: { error: e.message }, status: :service_unavailable
    end

    def callback
      return redirect_with(status: "erro", message: denial_message) if params[:error].present?

      credential = Marketplace::MercadoLivre::Callback.new(
        code: params[:code],
        state: params[:state]
      ).call

      redirect_with(
        status: "ok",
        message: "Conta #{credential.external_user_id} conectada"
      )
    rescue Marketplace::MercadoLivre::Callback::InvalidState => e
      redirect_with(status: "erro", message: e.message)
    rescue Marketplace::MercadoLivre::OauthClient::Error => e
      Rails.logger.error "[MercadoLivre] callback: #{e.class} #{e.message}"

      redirect_with(status: "erro", message: e.message)
    end

    def desconectar
      credential = MarketplaceCredential
                     .joins(:platform_account)
                     .where(platform_accounts: { tenant_id: accessible_tenants.select(:id) })
                     .find_by!(platform_account_id: params[:platform_account_id])

      credential.update!(
        status: :revoked,
        access_token: nil,
        refresh_token: nil
      )

      head :no_content
    rescue ActiveRecord::RecordNotFound
      render json: { error: "Conexão não encontrada" }, status: :not_found
    end

    private

    def optional_platform_account
      return if params[:platform_account_id].blank?

      PlatformAccount
        .where(tenant: accessible_tenants)
        .find(params[:platform_account_id])
    end

    def denial_message
      [params[:error], params[:error_description]].compact_blank.join(": ").presence ||
        "Autorização negada"
    end

    # Devolve o navegador para o frontend. Sem URL pública configurada não há
    # para onde voltar — aí responde JSON mesmo.
    def redirect_with(status:, message: nil)
      redirect_to(
        Marketplace::MercadoLivre::Settings.return_url(status: status, message: message),
        allow_other_host: true
      )
    rescue Marketplace::MercadoLivre::Settings::MissingPublicUrl
      render json: { status: status, message: message },
             status: status == "ok" ? :ok : :unprocessable_entity
    end
  end
end
