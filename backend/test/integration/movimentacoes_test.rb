require "test_helper"

class MovimentacoesTest < ActionDispatch::IntegrationTest
  SENHA = "senha-bem-longa".freeze

  setup do
    @tenant = criar_tenant
    @dono = criar_usuario(tenant: @tenant, papel: :owner)
    @dono.update!(password: SENHA)
    @conta = criar_conta(tenant: @tenant, metadata: {
      "omie_conta_corrente_id" => "6455415244",
      "omie_conta_corrente_destino_id" => "12557610062"
    })

    post "/auth/login", params: { email: @dono.email, password: SENHA }, as: :json

    @cabecalhos = { "Authorization" => "Bearer #{response.parsed_body['token']}",
                    "X-Tenant-Id" => @tenant.id.to_s }
  end

  def saque
    criar_lancamento(tenant: @tenant, conta: @conta, tipo: :settlement, direcao: :debit,
                     valor: 1000, ocorrido_em: 2.days.ago)
  end

  test "transferir roda como simulação sem escrita liberada" do
    saque

    com_env("OMIE_ALLOW_WRITES" => nil) do
      post "/movimentacoes/transferir", params: {}, headers: @cabecalhos, as: :json
    end

    assert_response :success
    assert response.parsed_body.dig("resumo", "simulacao"), "sem a trava aberta tem que simular"
    assert_equal 1, response.parsed_body.dig("resumo", "lancaria")
  end

  test "falta de configuração é erro acionável, não 500" do
    saque
    @conta.update!(metadata: @conta.metadata.except("omie_conta_corrente_destino_id"))

    com_env("OMIE_CONTA_CORRENTE_DESTINO_ID" => nil) do
      post "/movimentacoes/transferir", params: { dry_run: false },
                                        headers: @cabecalhos, as: :json
    end

    assert_response :unprocessable_content
    assert_includes response.parsed_body["error"], "destino"
  end

  test "pagar devolve o resumo por lançamento" do
    pedido = criar_pedido(tenant: @tenant, conta: @conta)
    nota = criar_nota(tenant: @tenant, pedido: pedido, numero: "0003337372", valor: 100)
    criar_lancamento(tenant: @tenant, conta: @conta, tipo: :payment, direcao: :debit,
                     valor: 100, pedido: pedido, nota: nota, ocorrido_em: 2.days.ago)

    post "/movimentacoes/pagar", params: {}, headers: @cabecalhos, as: :json

    assert_response :success
    # Sem título correspondente no OMIE, o caso é contado em vez de sumir.
    assert_equal 1, response.parsed_body.dig("resumo", "titulo_nao_encontrado")
  end

  test "data inválida não vira erro de servidor" do
    post "/movimentacoes/transferir", params: { start_date: "31/02/abc" },
                                      headers: @cabecalhos, as: :json

    assert_response :bad_request
  end

  test "quem não pode escrever não movimenta dinheiro" do
    membro = criar_usuario(tenant: @tenant, papel: :member)
    membro.update!(password: SENHA)

    post "/auth/login", params: { email: membro.email, password: SENHA }, as: :json

    cabecalhos = { "Authorization" => "Bearer #{response.parsed_body['token']}",
                   "X-Tenant-Id" => @tenant.id.to_s }

    post "/movimentacoes/transferir", params: {}, headers: cabecalhos, as: :json

    assert_response :forbidden
  end

  test "sem token não movimenta" do
    post "/movimentacoes/transferir", params: {}, as: :json

    assert_response :unauthorized
  end
end
