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

  # O extrato responde "como o saldo chegou aqui", que é a pergunta que o cartão de saldo
  # não responde. Sem conta pedida, a primeira ativa: a tela abre com algo na frente do
  # usuário em vez de um seletor vazio.
  test "extrato traz os movimentos e aponta onde o saldo se separou" do
    venda = criar_lancamento(tenant: @tenant, conta: @conta, valor: 100,
                             ocorrido_em: 2.days.ago)

    venda.update!(raw_payload: { "DESCRIPTION" => "payment", "SOURCE_ID" => "111",
                                 "BALANCE_AMOUNT" => "100" })

    # A plataforma diz 260; nós registramos 60 a mais dos 100. Faltam 100 do nosso lado.
    outra = criar_lancamento(tenant: @tenant, conta: @conta, valor: 60,
                             ocorrido_em: 1.day.ago)

    outra.update!(raw_payload: { "DESCRIPTION" => "payment", "SOURCE_ID" => "222",
                                 "BALANCE_AMOUNT" => "260" })

    get "/saldos/extrato", headers: @cabecalhos

    assert_response :success

    corpo = response.parsed_body

    assert_equal @conta.id, corpo.dig("conta", "id")
    assert_equal 2, corpo["total_de_linhas"]
    assert_equal "222", corpo.dig("primeira_divergencia", "referencia")
    assert_equal "-100.0", corpo.dig("primeira_divergencia", "salto")
  end

  test "sem token não se lê o extrato" do
    get "/saldos/extrato"

    assert_response :unauthorized
  end

  # A conta pedida tem que ser DESTA empresa. Sem isso, trocar o id na URL leria o extrato
  # de outro cliente — é o mesmo dado financeiro, só de outra pessoa.
  test "extrato de conta de outra empresa não é lido" do
    outra_empresa = criar_tenant
    conta_alheia = criar_conta(tenant: outra_empresa)

    get "/saldos/extrato", params: { platform_account_id: conta_alheia.id }, headers: @cabecalhos

    assert_response :not_found
  end
end
