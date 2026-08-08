module Integracoes
  class AmazonController < ApplicationController
    allow_unauthenticated :callback

    before_action :require_tenant!, only: :autorizar

    before_action :authorize_write!, only: :autorizar

    def autorizar
      resultado = Marketplace::Amazon::Authorization.new(
        tenant: current_tenant,
        user: current_user,
        platform_account: optional_platform_account
      ).call

      render json: resultado
    rescue Marketplace::Amazon::OauthClient::ConfigError,
           Marketplace::Amazon::Settings::MissingConfig => e
      render json: { error: e.message }, status: :service_unavailable
    end

    def callback
      credencial = Marketplace::Amazon::Callback.new(
        code: params[:spapi_oauth_code],
        selling_partner_id: params[:selling_partner_id],
        state: params[:state]
      ).call

      redirect_with(status: "ok", message: "Conta #{credencial.external_user_id} conectada")
    rescue Marketplace::Amazon::Callback::InvalidState,
           Marketplace::Amazon::Callback::MissingSeller => e
      redirect_with(status: "erro", message: e.message)
    rescue Marketplace::Amazon::OauthClient::Error => e
      Rails.logger.error "[Amazon] callback: #{e.class} #{e.message}"

      redirect_with(status: "erro", message: e.message)
    end

    private

    def optional_platform_account
      return if params[:platform_account_id].blank?

      PlatformAccount
        .where(tenant: accessible_tenants)
        .find(params[:platform_account_id])
    end

    def redirect_with(status:, message: nil)
      redirect_to(
        Marketplace::Amazon::Settings.return_url(status: status, message: message),
        allow_other_host: true
      )
    rescue Marketplace::Amazon::Settings::MissingConfig
      render json: { status: status, message: message },
             status: status == "ok" ? :ok : :unprocessable_entity
    end
  end
end
