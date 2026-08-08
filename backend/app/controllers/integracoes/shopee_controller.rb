module Integracoes
  class ShopeeController < ApplicationController
    # A Shopee redireciona o navegador do lojista para cá, sem a nossa sessão.
    allow_unauthenticated :callback

    before_action :require_tenant!, only: :autorizar

    before_action :authorize_write!, only: :autorizar

    def autorizar
      resultado = Marketplace::Shopee::Authorization.new(
        tenant: current_tenant,
        user: current_user,
        platform_account: optional_platform_account
      ).call

      render json: resultado
    rescue Marketplace::Shopee::Settings::MissingConfig, Marketplace::Shopee::Client::Error => e
      render json: { error: e.message }, status: :service_unavailable
    end

    def callback
      credencial = Marketplace::Shopee::Callback.new(
        code: params[:code],
        shop_id: params[:shop_id],
        state: params[:state]
      ).call

      redirect_with(status: "ok", message: "Loja #{credencial.external_user_id} conectada")
    rescue Marketplace::Shopee::Callback::InvalidState,
           Marketplace::Shopee::Callback::MissingShop => e
      redirect_with(status: "erro", message: e.message)
    rescue Marketplace::Shopee::Client::Error => e
      Rails.logger.error "[Shopee] callback: #{e.class} #{e.message}"

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
        Marketplace::Shopee::Settings.return_url(status: status, message: message),
        allow_other_host: true
      )
    rescue Marketplace::Shopee::Settings::MissingConfig
      render json: { status: status, message: message },
             status: status == "ok" ? :ok : :unprocessable_entity
    end
  end
end
