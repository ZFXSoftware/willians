module Integracoes
  # Desconectar não depende da plataforma: revoga a credencial da conta,
  # qualquer que seja o marketplace.
  class ConexoesController < ApplicationController
    before_action :authorize_write!

    def destroy
      credencial = MarketplaceCredential
                     .joins(:platform_account)
                     .where(platform_accounts: { tenant_id: accessible_tenants.select(:id) })
                     .find_by!(platform_account_id: params[:platform_account_id])

      credencial.update!(
        status: :revoked,
        access_token: nil,
        refresh_token: nil
      )

      head :no_content
    rescue ActiveRecord::RecordNotFound
      render json: { error: "Conexão não encontrada" }, status: :not_found
    end
  end
end
