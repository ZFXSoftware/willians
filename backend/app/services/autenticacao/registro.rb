module Autenticacao
  # Cadastro self-service: quem se registra cria a própria organização e entra
  # como owner dela. Não existe fluxo de convite ainda — um usuário só entra em
  # um tenant existente por criação manual do vínculo.
  class Registro
    def initialize(name:, email:, password:, tenant_name: nil, document: nil)
      @name = name

      @email = email

      @password = password

      @tenant_name = tenant_name.presence || "Organização de #{name}"

      @document = document
    end

    # => User (levanta ActiveRecord::RecordInvalid em falha de validação)
    def call
      ActiveRecord::Base.transaction do
        user = create_user!

        tenant = create_tenant!

        TenantUser.create!(
          tenant: tenant,
          user: user,
          role: :owner
        )

        user
      end
    end

    private

    attr_reader :name,
                :email,
                :password,
                :tenant_name,
                :document

    def create_user!
      User.create!(
        name: name,
        email: email,
        password: password,
        status: :active
      )
    end

    def create_tenant!
      Tenant.create!(
        name: tenant_name,
        document: document,
        status: :active
      )
    end
  end
end
