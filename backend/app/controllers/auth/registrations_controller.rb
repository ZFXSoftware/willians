module Auth
  class RegistrationsController < ApplicationController
    allow_unauthenticated :create

    def create
      user = Autenticacao::Registro.new(**registro_params).call

      session = issue_session(user)

      render json: {
        **session_payload(session),
        user: user_payload(user),
        tenants: tenants_payload(user)
      }, status: :created
    rescue ActiveRecord::RecordInvalid => e
      render json: {
        error: "Não foi possível criar a conta",
        details: e.record.errors.full_messages
      }, status: :unprocessable_entity
    end

    private

    def registro_params
      {
        name: params[:name],
        email: params[:email],
        password: params[:password],
        tenant_name: params[:tenant_name],
        document: params[:document]
      }
    end

    def issue_session(user)
      user.update_column(:last_login_at, Time.current)

      Session.issue!(
        user: user,
        ip_address: request.remote_ip,
        user_agent: request.user_agent
      )
    end
  end
end
