require "test_helper"

# Convite por link: o admin gera, envia por fora, e quem recebe define a
# própria senha. A senha nunca passa pelas mãos de quem convidou.
class EquipeTest < ActionDispatch::IntegrationTest
  SENHA = "senha-bem-longa".freeze

  setup do
    @tenant = criar_tenant(nome: "Empresa do Teste")
    @dono = criar_usuario(tenant: @tenant, papel: :owner)
    @dono.update!(password: SENHA)
    @cabecalhos = entrar(@dono.email)
  end

  def entrar(email)
    post "/auth/login", params: { email: email, password: SENHA }, as: :json

    { "Authorization" => "Bearer #{response.parsed_body['token']}",
      "X-Tenant-Id" => @tenant.id.to_s }
  end

  def convidar(email:, role: "member", headers: nil)
    post "/equipe/convidar", params: { email: email, role: role },
                             headers: headers || @cabecalhos, as: :json

    response.parsed_body
  end

  def token_de(link) = link.split("/convite/").last

  # ------------------------------------------------------------------ listagem

  test "lista quem tem acesso e os papéis disponíveis" do
    get "/equipe", headers: @cabecalhos

    assert_response :success

    corpo = response.parsed_body

    assert_equal 1, corpo["membros"].size
    assert_equal @dono.email, corpo["membros"].first["email"]
    assert corpo["membros"].first["sou_eu"]
    assert_equal "owner", corpo["meu_papel"]
    assert_equal %w[owner admin member viewer], corpo["papeis"].map { |p| p["valor"] }
  end

  # ------------------------------------------------------------------- convite

  test "convite devolve o link uma única vez" do
    corpo = convidar(email: "novo@empresa.com", role: "admin")

    assert_response :created
    assert_includes corpo["link"], "/convite/"
    assert_includes corpo["aviso"], "não é exibido novamente"
    assert_equal "pendente", corpo["situacao"]

    # Ao recarregar a lista, o link não volta — só o SHA-256 ficou no banco.
    get "/equipe", headers: @cabecalhos

    pendente = response.parsed_body["convites"].first

    assert_equal "novo@empresa.com", pendente["email"]
    refute pendente.key?("link"), "o link não pode ser recuperável depois"
  end

  test "token não fica em claro no banco" do
    link = convidar(email: "novo@empresa.com")["link"]

    token = token_de(link)

    assert_equal 0, Convite.where(token_digest: token).count, "guardaria o token cru"
    assert_equal 1, Convite.where(token_digest: Convite.digest_for(token)).count
  end

  test "convidar de novo o mesmo e-mail invalida o link anterior" do
    primeiro = token_de(convidar(email: "novo@empresa.com")["link"])
    segundo = token_de(convidar(email: "novo@empresa.com")["link"])

    get "/convites/#{primeiro}"

    assert_response :not_found, "dois links válidos para a mesma pessoa confundem"

    get "/convites/#{segundo}"

    assert_response :success
  end

  test "não convida quem já está na empresa" do
    convidar(email: @dono.email)

    assert_response :unprocessable_content
    assert_includes response.parsed_body["error"], "já faz parte"
  end

  test "só owner convida outro owner" do
    admin = criar_usuario(tenant: @tenant, papel: :admin)
    admin.update!(password: SENHA)

    convidar(email: "chefe@empresa.com", role: "owner", headers: entrar(admin.email))

    assert_response :unprocessable_content
    assert_includes response.parsed_body["error"], "owner"

    convidar(email: "chefe@empresa.com", role: "owner")

    assert_response :created, "o owner pode"
  end

  test "quem só lê não convida ninguém" do
    leitor = criar_usuario(tenant: @tenant, papel: :viewer)
    leitor.update!(password: SENHA)

    convidar(email: "x@empresa.com", headers: entrar(leitor.email))

    assert_response :forbidden

    get "/equipe", headers: entrar(leitor.email)

    assert_response :success, "ver quem tem acesso continua liberado"
  end

  # -------------------------------------------------------------------- aceite

  test "quem recebe o link define a própria senha e já entra" do
    link = convidar(email: "novo@empresa.com", role: "admin")["link"]
    token = token_de(link)

    get "/convites/#{token}"

    assert_response :success
    assert_equal "Empresa do Teste", response.parsed_body["empresa"]
    refute response.parsed_body["usuario_existente"]

    post "/convites/#{token}/aceitar",
         params: { name: "Pessoa Nova", password: "senha-escolhida-por-mim" }, as: :json

    assert_response :created
    assert response.parsed_body["token"].present?, "entra já autenticada"

    usuario = User.find_by!(email: "novo@empresa.com")

    assert_equal "admin", TenantUser.find_by!(tenant: @tenant, user: usuario).role
    assert User.authenticate_by(email: "novo@empresa.com", password: "senha-escolhida-por-mim")
  end

  test "o link é de uso único" do
    token = token_de(convidar(email: "novo@empresa.com")["link"])

    post "/convites/#{token}/aceitar", params: { name: "A", password: "senha-escolhida-por-mim" }, as: :json

    assert_response :created

    post "/convites/#{token}/aceitar", params: { name: "B", password: "outra-senha-longa-aqui" }, as: :json

    assert_response :not_found
  end

  test "link expirado é recusado" do
    token = token_de(convidar(email: "novo@empresa.com")["link"])

    Convite.last.update_columns(expires_at: 1.minute.ago)

    get "/convites/#{token}"

    assert_response :not_found
  end

  test "link revogado para de valer na hora" do
    token = token_de(convidar(email: "novo@empresa.com")["link"])

    delete "/equipe/convites/#{Convite.last.id}", headers: @cabecalhos

    assert_response :success

    get "/convites/#{token}"

    assert_response :not_found
  end

  test "senha curta é recusada" do
    token = token_de(convidar(email: "novo@empresa.com")["link"])

    post "/convites/#{token}/aceitar", params: { name: "A", password: "curta" }, as: :json

    assert_response :unprocessable_content
    assert_nil User.find_by(email: "novo@empresa.com")
  end

  # ------------------------------------------------- o risco que mais importa

  test "convite NÃO troca a senha de quem já tem conta" do
    # Uma pessoa que já usa o sistema em OUTRA empresa.
    outra = criar_tenant
    existente = criar_usuario(tenant: outra, email: "ja.existe@empresa.com")
    existente.update!(password: "a-senha-original-dela")

    token = token_de(convidar(email: "ja.existe@empresa.com", role: "owner")["link"])

    get "/convites/#{token}"

    assert response.parsed_body["usuario_existente"], "a tela precisa saber que não pede senha"

    post "/convites/#{token}/aceitar",
         params: { name: "Invasor", password: "senha-que-o-invasor-quer" }, as: :json

    assert_response :success
    assert response.parsed_body["ja_tinha_conta"]
    # Sem esta garantia, qualquer admin tomaria a conta de qualquer usuário do
    # sistema convidando o e-mail dele.
    assert User.authenticate_by(email: "ja.existe@empresa.com", password: "a-senha-original-dela"),
           "a senha original tem que continuar valendo"
    refute User.authenticate_by(email: "ja.existe@empresa.com", password: "senha-que-o-invasor-quer")
    refute_equal "Invasor", existente.reload.name, "o nome também não pode ser sobrescrito"

    # Mas o acesso à empresa foi concedido, que é o propósito do convite.
    assert TenantUser.exists?(tenant: @tenant, user: existente)
  end

  # ------------------------------------------------------------------- membros

  test "altera o papel de um membro" do
    membro = criar_usuario(tenant: @tenant, papel: :viewer)
    vinculo = TenantUser.find_by!(tenant: @tenant, user: membro)

    patch "/equipe/membros/#{vinculo.id}", params: { role: "admin" },
                                           headers: @cabecalhos, as: :json

    assert_response :success
    assert_equal "admin", vinculo.reload.role
    assert vinculo.can_write?
  end

  test "a empresa não pode ficar sem owner" do
    meu_vinculo = TenantUser.find_by!(tenant: @tenant, user: @dono)

    patch "/equipe/membros/#{meu_vinculo.id}", params: { role: "viewer" },
                                               headers: @cabecalhos, as: :json

    assert_response :unprocessable_content
    assert_includes response.parsed_body["error"], "owner"

    delete "/equipe/membros/#{meu_vinculo.id}", headers: @cabecalhos

    assert_response :unprocessable_content
    assert_equal "owner", meu_vinculo.reload.role
  end

  test "remove um membro" do
    membro = criar_usuario(tenant: @tenant, papel: :member)
    vinculo = TenantUser.find_by!(tenant: @tenant, user: membro)

    delete "/equipe/membros/#{vinculo.id}", headers: @cabecalhos

    assert_response :no_content
    refute TenantUser.exists?(vinculo.id)
    # A pessoa continua existindo; perdeu o acesso a ESTA empresa.
    assert User.exists?(membro.id)
  end

  test "membro de outra empresa não é alcançável" do
    outra = criar_tenant
    alheio = criar_usuario(tenant: outra)
    vinculo = TenantUser.find_by!(tenant: outra, user: alheio)

    patch "/equipe/membros/#{vinculo.id}", params: { role: "viewer" },
                                           headers: @cabecalhos, as: :json

    assert_response :not_found
    assert_equal "owner", vinculo.reload.role
  end

  test "sem token não se vê a equipe" do
    get "/equipe"

    assert_response :unauthorized
  end
end
