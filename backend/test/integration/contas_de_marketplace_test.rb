require "test_helper"

# Conectar a conta ERRADA é fácil: o OAuth autoriza a que estiver logada no
# navegador, e quem tem duas lojas conecta a de sempre sem perceber. Estes
# testes prendem a saída — e, principalmente, o que ela se recusa a destruir.
class ContasDeMarketplaceTest < ActionDispatch::IntegrationTest
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

  test "conta sem histórico pode ser removida" do
    delete "/integracoes/contas/#{@conta.id}", headers: @cabecalhos

    assert_response :no_content
    assert_nil PlatformAccount.find_by(id: @conta.id)
  end

  # O caso REAL, que o teste acima não pegava por criar a conta na mão: quem
  # passou pelo OAuth deixa um oauth_state apontando para a conta. A FK existe
  # no banco e o modelo não declarava a associação, então o destroy levantava
  # violação de chave estrangeira e a conta ficava lá.
  test "conta que passou pelo OAuth também pode ser removida" do
    OauthState.issue!(
      platform: @conta.platform, tenant: @tenant, user: @dono, platform_account: @conta
    )

    delete "/integracoes/contas/#{@conta.id}", headers: @cabecalhos

    assert_response :no_content
    assert_nil PlatformAccount.find_by(id: @conta.id)
    assert_equal 0, OauthState.where(platform_account_id: @conta.id).count
  end

  test "conta com lançamento NÃO é apagada" do
    criar_lancamento(tenant: @tenant, conta: @conta, valor: 250)

    delete "/integracoes/contas/#{@conta.id}", headers: @cabecalhos

    assert_response :unprocessable_entity

    # O ponto: apagar levaria pedidos e lançamentos em cascata. Destruir
    # histórico financeiro em silêncio é pior do que recusar.
    assert PlatformAccount.exists?(@conta.id)
    assert_equal 1, response.parsed_body["lancamentos"]
    assert_match(/[Aa]rquive/, response.parsed_body["hint"])
  end

  test "arquivar tira da operação e preserva o histórico" do
    criar_lancamento(tenant: @tenant, conta: @conta, valor: 250)

    post "/integracoes/contas/#{@conta.id}/arquivar", headers: @cabecalhos

    assert_response :success
    assert_equal "inactive", @conta.reload.status
    assert_equal 1, @conta.financial_entries.count
  end

  test "arquivar também revoga a credencial" do
    MarketplaceCredential.create!(
      tenant: @tenant, platform_account: @conta, platform: @conta.platform,
      status: :connected, access_token: "AT-1", expires_at: 4.hours.from_now
    )

    post "/integracoes/contas/#{@conta.id}/arquivar", headers: @cabecalhos

    credencial = @conta.reload.marketplace_credential

    assert credencial.revoked?
    assert_nil credencial.access_token, "token da loja errada não pode continuar guardado"
  end

  test "conta arquivada sai da sincronização automática" do
    MarketplaceCredential.create!(
      tenant: @tenant, platform_account: @conta, platform: @conta.platform,
      status: :connected, access_token: "AT-1", expires_at: 4.hours.from_now
    )

    post "/integracoes/contas/#{@conta.id}/arquivar", headers: @cabecalhos

    chamadas = []

    corpo = -> { chamadas << platform_account.id }

    com_metodo(Marketplace::Ingestors::MarketplaceIngestor, :call, corpo) do
      Marketplace::SincronizacaoService.new(tenant: @tenant).call
    end

    assert_empty chamadas
  end

  test "não dá para remover conta de outra empresa" do
    estranha = criar_conta(tenant: criar_tenant)

    delete "/integracoes/contas/#{estranha.id}", headers: @cabecalhos

    assert_response :not_found
    assert PlatformAccount.exists?(estranha.id)
  end

  test "quem só lê não remove nem arquiva" do
    leitor = criar_usuario(tenant: @tenant, papel: :viewer)
    leitor.update!(password: SENHA)

    post "/auth/login", params: { email: leitor.email, password: SENHA }, as: :json

    cabecalhos = { "Authorization" => "Bearer #{response.parsed_body['token']}",
                   "X-Tenant-Id" => @tenant.id.to_s }

    delete "/integracoes/contas/#{@conta.id}", headers: cabecalhos
    assert_response :forbidden

    post "/integracoes/contas/#{@conta.id}/arquivar", headers: cabecalhos
    assert_response :forbidden

    assert PlatformAccount.exists?(@conta.id)
  end
end
