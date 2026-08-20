module Authentication
  extend ActiveSupport::Concern

  included do
    before_action :authenticate!

    before_action :definir_contexto
  end

  class_methods do
    def allow_unauthenticated(*actions)
      skip_before_action :authenticate!, only: actions
    end
  end

  private

  # Credencial de usuário tem precedência sobre a de serviço. Se as duas vierem
  # juntas, o pedido vale pelo usuário — o token de serviço nunca eleva o
  # privilégio de uma requisição que já se identificou.
  def authenticate!
    return authenticate_user! if bearer_token.present?

    return true if service_authenticated?

    render_unauthorized
  end

  def authenticate_user!
    return render_unauthorized if current_session.blank?

    current_session.touch_usage!

    return render_forbidden("Usuário suspenso") unless current_user.active?

    true
  end

  def current_session
    return @current_session if defined?(@current_session)

    @current_session = Session.authenticate(bearer_token)
  end

  def current_user
    current_session&.user
  end

  def bearer_token
    header = request.headers["Authorization"].to_s

    header[/\ABearer (.+)\z/, 1]
  end

  # Chamador máquina-a-máquina (scheduler/worker do gateway). Não tem usuário e
  # pode operar sobre todos os tenants — por isso o token vive só no ambiente do
  # servidor e nunca é entregue ao browser.
  def service_authenticated?
    return @service_authenticated if defined?(@service_authenticated)

    expected = ENV["SERVICE_API_TOKEN"].to_s

    provided = request.headers["X-Service-Token"].to_s

    @service_authenticated =
      bearer_token.blank? &&
      expected.present? &&
      provided.present? &&
      ActiveSupport::SecurityUtils.secure_compare(expected, provided)
  end

  def accessible_tenants
    return Tenant.all if service_authenticated?

    current_user.tenants
  end

  # Tenant do contexto: header X-Tenant-Id, param tenant_id, ou o único tenant
  # do usuário quando não há ambiguidade.
  def current_tenant
    return @current_tenant if defined?(@current_tenant)

    requested = request.headers["X-Tenant-Id"].presence || params[:tenant_id].presence

    @current_tenant =
      if requested.present?
        accessible_tenants.find_by(id: requested)
      elsif !service_authenticated? && accessible_tenants.count == 1
        accessible_tenants.first
      end
  end

  # As credenciais de integração vivem por tenant, e os clientes de API são
  # construídos fundo na pilha, longe de quem conhece o tenant da requisição.
  def definir_contexto
    Current.user = current_user

    # Rotas públicas (cadastro, login, callback de OAuth) passam por aqui sem
    # ninguém identificado — e aí não há tenant para resolver.
    Current.tenant = current_tenant if current_user || service_authenticated?

    true
  end

  def require_tenant!
    return true if current_tenant

    render json: {
      error: "Tenant não informado ou sem acesso",
      hint: "Envie o header X-Tenant-Id com um tenant ao qual você pertence"
    }, status: :bad_request

    false
  end

  def current_membership
    return if service_authenticated?

    @current_membership ||= current_user&.membership_for(current_tenant)
  end

  def authorize_write!
    return true if service_authenticated?

    return true if current_membership&.can_write?

    render_forbidden("Seu perfil não permite executar esta operação")

    false
  end

  def render_unauthorized
    render json: { error: "Não autenticado" }, status: :unauthorized
  end

  def render_forbidden(message = "Acesso negado")
    render json: { error: message }, status: :forbidden
  end
end
