module Auth
  class MeController < ApplicationController
    def show
      return render json: { service: true, tenants: [] }, status: :ok if service_authenticated?

      render json: {
        user: user_payload(current_user),
        tenants: tenants_payload(current_user),
        current_tenant_id: current_tenant&.id,
        session: {
          expires_at: current_session.expires_at,
          last_used_at: current_session.last_used_at
        }
      }
    end
  end
end
