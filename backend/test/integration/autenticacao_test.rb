require "test_helper"

# Antes isto era um script de curl contra o container. Como teste de integração
# roda no CI, isola o banco e ainda descreve o contrato de cada rota.
class AutenticacaoTest < ActionDispatch::IntegrationTest
  SENHA = "senha-bem-longa".freeze

  LEITURAS = %w[painel divergencias integracoes conciliacoes/registros].freeze

  setup do
    @email = "ana#{SecureRandom.hex(4)}@teste.com"

    post "/auth/register", params: { name: "Ana", email: @email, password: SENHA,
                                     tenant_name: "Org Ana" }, as: :json

    @cadastro = response.parsed_body
    @token = @cadastro["token"]
  end

  def autenticado = { "Authorization" => "Bearer #{@token}" }

  test "cadastro devolve token e nunca a senha" do
    assert_response :success
    assert @token.present?
    refute_match(/password|digest/i, response.body)
  end

  test "email duplicado é recusado" do
    post "/auth/register", params: { name: "X", email: @email, password: SENHA }, as: :json

    assert_response :unprocessable_content
  end

  test "senha errada não autentica" do
    post "/auth/login", params: { email: @email, password: "errada" }, as: :json

    assert_response :unauthorized
  end

  test "identidade exige token" do
    get "/auth/me"

    assert_response :unauthorized

    get "/auth/me", headers: autenticado

    assert_response :success
  end

  test "toda leitura é fechada sem token" do
    LEITURAS.each do |rota|
      get "/#{rota}"

      assert_response :unauthorized, "/#{rota} respondeu sem token"

      get "/#{rota}", headers: autenticado

      assert_response :success, "/#{rota} negou um token válido"
    end
  end

  test "conciliação exige token" do
    post "/conciliacoes/processar", params: {}, as: :json

    assert_response :unauthorized
  end

  test "conta de outro tenant não é visível" do
    outro = Tenant.create!(name: "Outro #{SecureRandom.hex(3)}", status: :active)
    conta = PlatformAccount.create!(tenant: outro, platform: "mercado_livre",
                                    external_id: "alheia-#{SecureRandom.hex(3)}",
                                    name: "Alheia", status: :active)

    post "/conciliacoes/processar", params: { platform_account_id: conta.id },
                                    headers: autenticado, as: :json

    assert_response :not_found, "vazar conta de outro tenant é vazamento de dado financeiro"
  end

  test "token de serviço vale para máquina, chute não vale" do
    com_env("SERVICE_API_TOKEN" => "token-de-servico-do-teste") do
      post "/conciliacoes/processar", params: {},
                                      headers: { "X-Service-Token" => "token-de-servico-do-teste" },
                                      as: :json

      assert_response :success

      post "/conciliacoes/processar", params: {},
                                      headers: { "X-Service-Token" => "chute" }, as: :json

      assert_response :unauthorized
    end
  end

  test "logout revoga o token na hora" do
    delete "/auth/logout", headers: autenticado

    assert_response :no_content

    get "/auth/me", headers: autenticado

    assert_response :unauthorized
  end
end
