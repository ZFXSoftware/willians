class ApplicationController < ActionController::API
  include Authentication

  private

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
