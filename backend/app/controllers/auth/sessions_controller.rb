module Auth
  class SessionsController < ApplicationController
    allow_unauthenticated :create

    def create
      # authenticate_by gasta o mesmo tempo com email inexistente e senha
      # errada, para não vazar quais emails existem.
      user = User.authenticate_by(
        email: params[:email].to_s.strip.downcase,
        password: params[:password].to_s
      )

      return render json: { error: "Email ou senha inválidos" }, status: :unauthorized if user.blank?

      return render json: { error: "Usuário suspenso" }, status: :forbidden unless user.active?

      user.update_column(:last_login_at, Time.current)

      session = Session.issue!(
        user: user,
        ip_address: request.remote_ip,
        user_agent: request.user_agent
      )

      render json: {
        **session_payload(session),
        user: user_payload(user),
        tenants: tenants_payload(user)
      }
    end

    def destroy
      current_session&.revoke!

      head :no_content
    end
  end
end
