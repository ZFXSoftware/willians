require "test_helper"

# Briefing 2.5. As plataformas não aceitam contestação por link parametrizado,
# então o valor está em levar ao lugar certo e entregar os dados prontos. O
# erro caro aqui seria mandar o usuário para uma URL quebrada.
class ContestacaoTest < ActionDispatch::IntegrationTest
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

  def divergencia(com_pedido: true, com_nota: true)
    pedido = com_pedido ? criar_pedido(tenant: @tenant, conta: @conta, external_id: "2000000111") : nil
    nota = com_nota && pedido ? criar_nota(tenant: @tenant, pedido: pedido, numero: "251372") : nil

    lancamento = criar_lancamento(tenant: @tenant, conta: @conta, pedido: pedido, nota: nota,
                                  valor: 150, external_id: "MLREL-PAY-111-SALE")

    DivergenceReport.create!(
      tenant_id: @tenant.id, financial_entry_id: lancamento.id,
      divergence_type: "valor_divergente_na_baixa", status: "open",
      expected_amount: 140, received_amount: 150, difference_amount: 10
    )
  end

  test "monta o link da plataforma com o pedido" do
    d = divergencia

    get "/divergencias/#{d.id}/contestacao", headers: @cabecalhos

    assert_response :success

    corpo = response.parsed_body

    assert_equal "https://www.mercadolivre.com.br/vendas/2000000111/detalhe", corpo["url"]
    # O sistema não garante o caminho da central: ele muda e não é documentado.
    refute corpo["url_confirmada"]
  end

  test "modelo configurado pelo usuário substitui o padrão" do
    d = divergencia

    put "/integracoes/configuracoes/mercado_livre",
        params: { valores: { url_contestacao: "https://exemplo.com/pedido/{pedido}/nf/{nf}" } },
        headers: @cabecalhos, as: :json

    get "/divergencias/#{d.id}/contestacao", headers: @cabecalhos

    assert_equal "https://exemplo.com/pedido/2000000111/nf/251372", response.parsed_body["url"]
  end

  test "sem pedido, cai na central genérica em vez de link quebrado" do
    d = divergencia(com_pedido: false)

    get "/divergencias/#{d.id}/contestacao", headers: @cabecalhos

    url = response.parsed_body["url"]

    assert_equal "https://www.mercadolivre.com.br/ajuda", url
    refute_includes url, "{pedido}", "marcador não substituído viraria URL inválida"
  end

  test "entrega os dados prontos para colar" do
    d = divergencia

    get "/divergencias/#{d.id}/contestacao", headers: @cabecalhos

    corpo = response.parsed_body
    campos = corpo["campos"].to_h { |c| [c["rotulo"], c["valor"]] }

    assert_equal "2000000111", campos["Pedido"]
    assert_equal "251372", campos["Nota fiscal"]
    assert_equal "R$ 140,00", campos["Valor esperado"]
    assert_equal "R$ 150,00", campos["Valor recebido"]
    assert_equal "R$ 10,00", campos["Diferença"]

    assert_includes corpo["texto"], "R$ 10,00"
    assert_includes corpo["assunto"], "2000000111"
  end

  test "campo sem valor não aparece em branco" do
    d = divergencia(com_nota: false)

    get "/divergencias/#{d.id}/contestacao", headers: @cabecalhos

    rotulos = response.parsed_body["campos"].map { |c| c["rotulo"] }

    refute_includes rotulos, "Nota fiscal"
  end

  test "contestar registra o protocolo e move para em análise" do
    d = divergencia

    post "/divergencias/#{d.id}/contestar",
         params: { protocolo: "ML-998877", observacao: "Aberto pelo chat" },
         headers: @cabecalhos, as: :json

    assert_response :success
    assert_equal "analyzing", response.parsed_body["status"]
    assert_equal "ML-998877", response.parsed_body.dig("contestacao", "protocolo")
    assert_equal @dono.email, response.parsed_body.dig("contestacao", "por")
    assert d.reload.analyzing?
  end

  test "resolver fecha o caso com data e observação" do
    d = divergencia

    post "/divergencias/#{d.id}/resolver", params: { observacao: "Ajuste creditado" },
                                           headers: @cabecalhos, as: :json

    assert_response :success
    assert d.reload.resolved?
    assert d.resolved_at.present?
    assert_equal "Ajuste creditado", d.resolution_notes
  end

  test "divergência de outro tenant não é acessível" do
    outro = criar_tenant
    conta = criar_conta(tenant: outro)
    lancamento = criar_lancamento(tenant: outro, conta: conta)
    alheia = DivergenceReport.create!(tenant_id: outro.id, financial_entry_id: lancamento.id,
                                      divergence_type: "x", status: "open")

    get "/divergencias/#{alheia.id}/contestacao", headers: @cabecalhos

    assert_response :not_found
  end

  test "quem só lê não contesta nem resolve" do
    d = divergencia
    membro = criar_usuario(tenant: @tenant, papel: :member)
    membro.update!(password: SENHA)

    post "/auth/login", params: { email: membro.email, password: SENHA }, as: :json

    cabecalhos = { "Authorization" => "Bearer #{response.parsed_body['token']}",
                   "X-Tenant-Id" => @tenant.id.to_s }

    post "/divergencias/#{d.id}/contestar", params: {}, headers: cabecalhos, as: :json

    assert_response :forbidden

    get "/divergencias/#{d.id}/contestacao", headers: cabecalhos

    assert_response :success, "ver os dados continua liberado"
  end
end
