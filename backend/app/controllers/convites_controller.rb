# Recebimento do convite. Público por necessidade: quem abre o link ainda não
# tem conta, e é justamente o que vem fazer aqui.
#
# Toda a confiança vem do token, que é de uso único, tem validade e existe em
# claro apenas no link.
class ConvitesController < ApplicationController
  allow_unauthenticated :show, :aceitar

  before_action :carregar

  # O que a tela precisa para se desenhar, sem revelar nada de quem convidou.
  def show
    render json: {
      empresa: @convite.tenant.name,
      email: @convite.email,
      papel: @convite.role,
      expira_em: @convite.expires_at,
      # Muda o formulário: quem já tem conta não define senha, só entra.
      usuario_existente: User.exists?(email: @convite.email)
    }
  end

  def aceitar
    aceite = Autenticacao::AceiteDeConvite.new(
      convite: @convite, name: params[:name], password: params[:password]
    )

    if aceite.usuario_existente?
      # Já existe conta com este e-mail: o convite dá acesso à empresa, mas não
      # é caminho para trocar senha de ninguém.
      resultado = aceite.call

      return render json: {
        ja_tinha_conta: true,
        empresa: resultado.tenant.name,
        mensagem: "Sua conta já existia e agora tem acesso a #{resultado.tenant.name}. " \
                  "Entre com a sua senha de sempre."
      }, status: :ok
    end

    return erro("Escolha uma senha de pelo menos 12 caracteres") if params[:password].to_s.length < 12

    resultado = aceite.call

    sessao = Session.issue!(
      user: resultado.user, ip_address: request.remote_ip, user_agent: request.user_agent
    )

    resultado.user.update_column(:last_login_at, Time.current)

    render json: {
      **session_payload(sessao),
      user: user_payload(resultado.user),
      tenants: tenants_payload(resultado.user)
    }, status: :created
  rescue ActiveRecord::RecordInvalid => e
    render json: { error: "Não foi possível concluir", details: e.record.errors.full_messages },
           status: :unprocessable_content
  end

  private

  def carregar
    @convite = Convite.valido(params[:token])

    return if @convite

    # Mesma resposta para inexistente, expirado, usado e revogado: quem tem o
    # link não fica sabendo em qual dos casos caiu.
    render json: {
      error: "Convite inválido ou expirado",
      hint: "Peça um link novo a quem administra a empresa."
    }, status: :not_found
  end

  def erro(mensagem)
    render json: { error: mensagem }, status: :unprocessable_content
  end
end
