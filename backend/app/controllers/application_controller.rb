class ApplicationController < ActionController::API
  include Authentication

  MAX_PER_PAGE = 100

  DEFAULT_PER_PAGE = 25

  private

  def page
    [params[:page].to_i, 1].max
  end

  def per_page
    solicitado = params[:per_page].to_i

    return DEFAULT_PER_PAGE if solicitado <= 0

    [solicitado, MAX_PER_PAGE].min
  end

  # Pagina e devolve os itens já serializados junto com o meta.
  def paginated(scope)
    total = scope.count

    registros = scope.offset((page - 1) * per_page).limit(per_page)

    {
      items: registros.map { |registro| yield(registro) },
      meta: {
        page: page,
        per_page: per_page,
        total: total,
        total_pages: (total.to_f / per_page).ceil
      }
    }
  end

  def parse_date(value)
    return if value.blank?

    Date.parse(value.to_s)
  rescue Date::Error
    raise ArgumentError, "Data inválida: #{value}"
  end

  def user_payload(user)
    {
      id: user.id,
      name: user.name,
      email: user.email,
      status: user.status
    }
  end

  def tenants_payload(user)
    user
      .tenant_users
      .includes(:tenant)
      .map do |membership|
        {
          id: membership.tenant_id,
          name: membership.tenant.name,
          role: membership.role
        }
      end
  end

  def session_payload(session)
    {
      token: session.raw_token,
      expires_at: session.expires_at
    }.compact
  end
end
