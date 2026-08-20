require "test_helper"

class SaldosTest < ActionDispatch::IntegrationTest
  SENHA = "senha-bem-longa".freeze

  setup do
    @tenant = criar_tenant
    @dono = criar_usuario(tenant: @tenant, papel: :owner)
    @dono.update!(password: SENHA)
    @conta = criar_conta(tenant: @tenant)

    post "/auth/login", params: { email: @dono.email, password: SENHA }, as: :json

    @cabecalhos = { "Authorization" => "Bearer #{response.parsed_body['token']}",
                    "X-Tenant-Id" => @tenant.id.to_s }
  end

  def snapshot!(nosso:, plataforma:)
    PlatformBalanceSnapshot.create!(
      tenant: @tenant, platform_account: @conta, snapshot_date: Date.current,
      available_balance: nosso, platform_available_balance: plataforma,
      platform_total_balance: plataforma, difference_amount: (plataforma - nosso),
      platform_source: "relatorio_de_liberacoes"
    )
  end

  test "conta nunca conferida não aparece como se conferisse" do
    get "/saldos", headers: @cabecalhos

    assert_response :success

    item = response.parsed_body["items"].first

    assert_equal "nao_conferido", item["situacao"]
    assert_nil item["diferenca"]
    assert_equal 1, response.parsed_body.dig("resumo", "nao_conferido")
  end

  test "mostra os dois lados e a diferença" do
    snapshot!(nosso: 500, plataforma: 460)

    get "/saldos", headers: @cabecalhos

    item = response.parsed_body["items"].first

    assert_equal "divergente", item["situacao"]
    assert_equal "460.0", item.dig("saldo_plataforma", "disponivel")
    assert_equal "500.0", item.dig("saldo_interno", "disponivel")
    assert_equal "-40.0", item["diferenca"]
    assert_equal "relatorio_de_liberacoes", item["origem_do_saldo"]
  end

  test "diferença de centavos conta como confere" do
    snapshot!(nosso: 500, plataforma: BigDecimal("499.98"))

    get "/saldos", headers: @cabecalhos

    assert_equal "confere", response.parsed_body["items"].first["situacao"]
  end

  test "conferir exige permissão de escrita" do
    membro = criar_usuario(tenant: @tenant, papel: :member)
    membro.update!(password: SENHA)

    post "/auth/login", params: { email: membro.email, password: SENHA }, as: :json

    cabecalhos = { "Authorization" => "Bearer #{response.parsed_body['token']}",
                   "X-Tenant-Id" => @tenant.id.to_s }

    post "/saldos/conferir", params: {}, headers: cabecalhos, as: :json

    assert_response :forbidden

    get "/saldos", headers: cabecalhos

    assert_response :success, "leitura continua liberada"
  end

  test "sem token não se lê saldo" do
    get "/saldos"

    assert_response :unauthorized
  end

  test "conferir devolve o resumo por conta" do
    post "/saldos/conferir", params: {}, headers: @cabecalhos, as: :json

    assert_response :success
    # Sem integração conectada, a resposta honesta é "sem espelho".
    assert_equal 1, response.parsed_body.dig("resumo", "sem_espelho")
  end
end
