require "test_helper"

# A tela de configurações é por onde as chaves de API entram no sistema. O que
# ela não pode fazer, em nenhuma hipótese, é devolver um segredo já gravado.
class ConfiguracoesIntegracoesTest < ActionDispatch::IntegrationTest
  SENHA = "senha-bem-longa".freeze

  setup do
    @tenant = criar_tenant
    @dono = criar_usuario(tenant: @tenant, papel: :owner)
    @dono.update!(password: SENHA)
    @token = entrar(@dono.email)
  end

  def entrar(email)
    post "/auth/login", params: { email: email, password: SENHA }, as: :json

    response.parsed_body["token"]
  end

  def cabecalhos(token = @token)
    { "Authorization" => "Bearer #{token}", "X-Tenant-Id" => @tenant.id.to_s }
  end

  def provedor(chave, corpo = response.parsed_body)
    (corpo["provedores"] || [corpo]).find { |p| p["chave"] == chave }
  end

  def campo(provedor_chave, campo_chave)
    provedor(provedor_chave)["campos"].find { |c| c["chave"] == campo_chave }
  end

  test "lista o catálogo com o que falta preencher" do
    com_env("TINY_TOKEN" => nil) do
      get "/integracoes/configuracoes", headers: cabecalhos

      assert_response :success

      tiny = provedor("tiny")

      refute tiny["configurado"]
      assert_equal ["Token da API"], tiny["pendencias"]
      assert_equal "https://tiny.com.br/ajuda/api", tiny["documentacao"]
    end
  end

  test "grava a chave e passa a reportar configurado" do
    com_env("TINY_TOKEN" => nil) do
      put "/integracoes/configuracoes/tiny",
          params: { valores: { token: "token-secreto-do-tiny" } },
          headers: cabecalhos, as: :json

      assert_response :success
      assert provedor("tiny")["configurado"]
      assert_equal "token-secreto-do-tiny",
                   Integracoes::Config.get("tiny", :token, tenant: @tenant)
    end
  end

  test "segredo gravado nunca volta pela API" do
    put "/integracoes/configuracoes/tiny",
        params: { valores: { token: "token-secreto-do-tiny" } },
        headers: cabecalhos, as: :json

    refute_includes response.body, "token-secreto-do-tiny"

    get "/integracoes/configuracoes", headers: cabecalhos

    refute_includes response.body, "token-secreto-do-tiny"

    token = campo("tiny", "token")

    assert_nil token["valor"], "campo secreto não pode devolver o valor"
    assert token["preenchido"]
    assert_equal "••••••••tiny", token["pista"], "a pista confirma a chave sem revelá-la"
  end

  test "campo não secreto volta inteiro para poder ser editado" do
    put "/integracoes/configuracoes/mercado_livre",
        params: { valores: { client_id: "1234567890" } },
        headers: cabecalhos, as: :json

    assert_equal "1234567890", campo("mercado_livre", "client_id")["valor"]
  end

  test "valor vazio apaga a configuração e devolve o ambiente" do
    put "/integracoes/configuracoes/omie", params: { valores: { app_key: "chave-do-cliente" } },
                                          headers: cabecalhos, as: :json

    com_env("OMIE_APP_KEY" => "chave-do-ambiente") do
      put "/integracoes/configuracoes/omie", params: { valores: { app_key: "" } },
                                             headers: cabecalhos, as: :json

      assert_equal "ambiente", campo("omie", "app_key")["origem"]
      assert_equal "chave-do-ambiente", Integracoes::Config.get("omie", :app_key, tenant: @tenant)
    end
  end

  test "apagar por rota também desfaz a configuração" do
    put "/integracoes/configuracoes/omie", params: { valores: { app_key: "chave-do-cliente" } },
                                           headers: cabecalhos, as: :json

    delete "/integracoes/configuracoes/omie/app_key", headers: cabecalhos

    assert_response :success
    assert_equal 0, IntegrationSetting.where(tenant_id: @tenant.id, key: "app_key").count
  end

  test "campo ou integração desconhecida é recusada" do
    put "/integracoes/configuracoes/omie", params: { valores: { inventado: "x" } },
                                           headers: cabecalhos, as: :json

    assert_response :unprocessable_content

    put "/integracoes/configuracoes/nao_existe", params: { valores: {} },
                                                 headers: cabecalhos, as: :json

    assert_response :not_found
  end

  test "guarda quem gravou a chave" do
    put "/integracoes/configuracoes/tiny", params: { valores: { token: "t" } },
                                           headers: cabecalhos, as: :json

    assert_equal @dono.id, IntegrationSetting.find_by!(tenant_id: @tenant.id, key: "token").updated_by_id
  end

  test "quem não pode escrever não troca chave de API" do
    membro = criar_usuario(tenant: @tenant, papel: :member)
    membro.update!(password: SENHA)

    put "/integracoes/configuracoes/tiny", params: { valores: { token: "t" } },
                                           headers: cabecalhos(entrar(membro.email)), as: :json

    assert_response :forbidden

    # Mas continua enxergando o que está configurado.
    get "/integracoes/configuracoes", headers: cabecalhos(entrar(membro.email))

    assert_response :success
  end

  test "sem token não se lê nem se grava configuração" do
    get "/integracoes/configuracoes"

    assert_response :unauthorized

    put "/integracoes/configuracoes/tiny", params: { valores: { token: "t" } }, as: :json

    assert_response :unauthorized
  end

  test "a URL de retorno para cadastrar no portal é exibida" do
    com_env("APP_PUBLIC_URL" => "https://willians.exemplo") do
      get "/integracoes/configuracoes", headers: cabecalhos

      assert_equal "https://willians.exemplo/api/integracoes/shopee/callback",
                   response.parsed_body.dig("urls_de_retorno", "shopee")
    end
  end

  test "sem URL pública configurada a tela não quebra" do
    com_env("APP_PUBLIC_URL" => nil) do
      get "/integracoes/configuracoes", headers: cabecalhos

      assert_response :success
      assert_nil response.parsed_body.dig("urls_de_retorno", "shopee")
    end
  end
end
