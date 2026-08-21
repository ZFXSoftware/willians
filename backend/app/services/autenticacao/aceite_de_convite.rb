module Autenticacao
  # Transforma um convite válido em acesso.
  #
  # REGRA DE SEGURANÇA que dá o formato deste serviço: se já existe um usuário
  # com aquele e-mail, o convite NÃO toca na senha dele. Só cria o vínculo com
  # a empresa.
  #
  # Sem isso, qualquer admin de qualquer empresa poderia convidar o e-mail de
  # um usuário existente e, no aceite, redefinir a senha — tomando a conta dele
  # em todas as outras empresas. O convite dá acesso a UMA empresa; ele não é
  # um caminho para recuperar senha.
  class AceiteDeConvite
    class UsuarioJaExiste < StandardError; end

    Resultado = Struct.new(:user, :tenant, :vinculo_novo, keyword_init: true)

    def initialize(convite:, name: nil, password: nil)
      @convite = convite

      @name = name

      @password = password
    end

    def call
      existente = User.find_by(email: convite.email)

      ActiveRecord::Base.transaction do
        usuario = existente || criar_usuario!

        vinculo = TenantUser.find_or_initialize_by(tenant_id: convite.tenant_id, user_id: usuario.id)

        novo = vinculo.new_record?

        # Um convite não rebaixa quem já tem papel maior na empresa.
        vinculo.role = convite.role if novo

        vinculo.save!

        convite.update!(accepted_at: Time.current)

        Resultado.new(user: usuario, tenant: convite.tenant, vinculo_novo: novo)
      end
    end

    # Quem recebe o link precisa saber, antes de digitar, se vai criar conta ou
    # apenas entrar com a que já tem.
    def usuario_existente? = User.exists?(email: convite.email)

    private

    attr_reader :convite,
                :name,
                :password

    def criar_usuario!
      User.create!(
        name: name.presence || convite.email.split("@").first,
        email: convite.email,
        password: password,
        status: :active
      )
    end
  end
end
