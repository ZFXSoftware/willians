# Quem tem acesso à empresa, e os convites em aberto.
#
# Ler é liberado a qualquer membro: saber quem enxerga os dados financeiros da
# empresa não é privilégio. Alterar exige perfil de escrita.
class EquipeController < ApplicationController
  before_action :require_tenant!

  before_action :authorize_write!, only: %i[convidar revogar remover alterar_papel]

  PAPEIS = %w[owner admin member viewer].freeze

  def index
    render json: {
      membros: membros.map { |m| serialize_membro(m) },
      convites: convites_pendentes.map { |c| serialize_convite(c) },
      papeis: PAPEIS.map { |p| { valor: p, rotulo: rotulo(p), escreve: TenantUser::WRITE_ROLES.include?(p) } },
      meu_papel: current_membership&.role
    }
  end

  def convidar
    email = params[:email].to_s.strip.downcase

    return erro("Informe o e-mail") if email.blank?

    role = papel_solicitado

    return erro("Perfil inválido") if role.blank?

    return erro("Só um owner pode convidar outro owner") if role == "owner" && !sou_owner?

    if membros.any? { |m| m.user.email.casecmp?(email) }
      return erro("#{email} já faz parte desta empresa")
    end

    # Um convite pendente para o mesmo e-mail é substituído: dois links válidos
    # para a mesma pessoa só criam confusão sobre qual usar.
    convites_pendentes.where(email: email).update_all(revoked_at: Time.current)

    convite = Convite.emitir!(
      tenant: current_tenant, email: email, role: role, convidado_por: current_user
    )

    render json: serialize_convite(convite).merge(
      # O link só existe aqui. Recarregar a tela não o mostra de novo.
      link: link_para(convite),
      aviso: "Copie o link agora: ele não é exibido novamente."
    ), status: :created
  end

  def revogar
    convite = Convite.where(tenant_id: current_tenant.id).find_by(id: params[:id])

    return render json: { error: "Convite não encontrado" }, status: :not_found if convite.blank?

    convite.update!(revoked_at: Time.current)

    render json: serialize_convite(convite)
  end

  def alterar_papel
    vinculo = membros.find_by(id: params[:id])

    return render json: { error: "Membro não encontrado" }, status: :not_found if vinculo.blank?

    role = papel_solicitado

    return erro("Perfil inválido") if role.blank?

    return erro("Só um owner pode definir outro owner") if role == "owner" && !sou_owner?

    return erro("A empresa ficaria sem nenhum owner") if rebaixaria_o_ultimo_owner?(vinculo, role)

    vinculo.update!(role: role)

    render json: serialize_membro(vinculo.reload)
  end

  def remover
    vinculo = membros.find_by(id: params[:id])

    return render json: { error: "Membro não encontrado" }, status: :not_found if vinculo.blank?

    return erro("A empresa ficaria sem nenhum owner") if rebaixaria_o_ultimo_owner?(vinculo, nil)

    vinculo.destroy!

    head :no_content
  end

  private

  def membros
    TenantUser.where(tenant_id: current_tenant.id).includes(:user).order(:id)
  end

  def convites_pendentes
    Convite.where(tenant_id: current_tenant.id).pendentes.order(created_at: :desc)
  end

  def papel_solicitado
    valor = params[:role].to_s.strip

    PAPEIS.include?(valor) ? valor : nil
  end

  def sou_owner? = current_membership.nil? || current_membership.owner?

  # Sem owner, ninguém consegue mais promover ninguém — a empresa fica travada.
  def rebaixaria_o_ultimo_owner?(vinculo, novo_papel)
    return false unless vinculo.owner?

    return false if novo_papel == "owner"

    membros.where(role: :owner).count <= 1
  end

  def link_para(convite)
    base = ENV["APP_PUBLIC_URL"].presence || request.base_url

    "#{base.chomp('/')}/convite/#{convite.raw_token}"
  end

  def serialize_membro(vinculo)
    {
      id: vinculo.id,
      user_id: vinculo.user_id,
      nome: vinculo.user.name,
      email: vinculo.user.email,
      papel: vinculo.role,
      escreve: vinculo.can_write?,
      status: vinculo.user.status,
      ultimo_acesso: vinculo.user.last_login_at,
      sou_eu: vinculo.user_id == current_user&.id
    }
  end

  def serialize_convite(convite)
    {
      id: convite.id,
      email: convite.email,
      papel: convite.role,
      situacao: convite.situacao,
      expira_em: convite.expires_at,
      criado_em: convite.created_at,
      convidado_por: convite.convidado_por&.email
    }
  end

  def rotulo(papel)
    {
      "owner" => "Dono", "admin" => "Administrador",
      "member" => "Membro", "viewer" => "Somente leitura"
    }[papel]
  end

  def erro(mensagem)
    render json: { error: mensagem }, status: :unprocessable_content
  end
end
