require "test_helper"

class DevolucoesTest < ActionDispatch::IntegrationTest
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

  def estorno(pedido: nil)
    criar_lancamento(tenant: @tenant, conta: @conta, tipo: :refund, direcao: :debit,
                     valor: 40, pedido: pedido, ocorrido_em: 2.days.ago)
  end

  test "lista vazia não é erro" do
    get "/devolucoes", headers: @cabecalhos

    assert_response :success
    assert_empty response.parsed_body["items"]
    assert_equal 0, response.parsed_body.dig("resumo", "total")
  end

  test "rastrear costura o estorno à venda e diz o que falta" do
    pedido = criar_pedido(tenant: @tenant, conta: @conta)
    criar_nota(tenant: @tenant, pedido: pedido, numero: "000900100")
    estorno(pedido: pedido)

    post "/devolucoes/rastrear", params: {}, headers: @cabecalhos, as: :json

    assert_response :success
    assert_equal 1, response.parsed_body.dig("resumo", "aguardando_nota")

    get "/devolucoes", headers: @cabecalhos

    item = response.parsed_body["items"].first

    assert_equal "aguardando_nota", item["status"]
    assert_equal "000900100", item.dig("nota_de_venda", "numero")
    assert_nil item["nota_de_devolucao"]
    assert_includes item["pendencia"], "nota fiscal de devolução"
  end

  test "estorno órfão aparece com a pendência explicada" do
    estorno

    post "/devolucoes/rastrear", params: {}, headers: @cabecalhos, as: :json

    get "/devolucoes", params: { status: "sem_origem" }, headers: @cabecalhos

    assert_equal 1, response.parsed_body["items"].size
    assert_includes response.parsed_body["items"].first["pendencia"], "pedido de origem"
  end

  test "rastrear exige permissão de escrita" do
    membro = criar_usuario(tenant: @tenant, papel: :member)
    membro.update!(password: SENHA)

    post "/auth/login", params: { email: membro.email, password: SENHA }, as: :json

    cabecalhos = { "Authorization" => "Bearer #{response.parsed_body['token']}",
                   "X-Tenant-Id" => @tenant.id.to_s }

    post "/devolucoes/rastrear", params: {}, headers: cabecalhos, as: :json

    assert_response :forbidden

    get "/devolucoes", headers: cabecalhos

    assert_response :success
  end

  test "sem token não se lê devolução" do
    get "/devolucoes"

    assert_response :unauthorized
  end
end
