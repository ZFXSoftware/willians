require "test_helper"

# O razão inteiro, navegável.
#
# Existia só o "Últimas movimentações" do painel, que mostra as poucas mais
# recentes. Com milhares de lançamentos importados, não havia como responder
# "e os outros?" — nem procurar um pagamento específico.
class LancamentosTest < ActionDispatch::IntegrationTest
  SENHA = "senha-de-teste-123".freeze

  setup do
    @tenant = criar_tenant
    @conta = criar_conta(tenant: @tenant, plataforma: "mercado_livre")
    @dono = criar_usuario(tenant: @tenant, papel: :owner)
    @dono.update!(password: SENHA)

    post "/auth/login", params: { email: @dono.email, password: SENHA }, as: :json

    @cabecalhos = { "Authorization" => "Bearer #{response.parsed_body['token']}",
                    "X-Tenant-Id" => @tenant.id.to_s }
  end

  def lancamento(tipo:, direcao:, valor:, pagamento: nil, pedido: nil)
    FinancialEntry.create!(
      tenant: @tenant, platform_account: @conta, order: pedido,
      external_id: "MLREL-#{SecureRandom.hex(3)}", source: :mercado_livre,
      entry_type: tipo, direction: direcao, amount: valor,
      occurred_at: 2.days.ago, status: :settled,
      metadata: pagamento ? { "source_id" => pagamento } : {}
    )
  end

  test "lista o razão com os totais do filtro" do
    lancamento(tipo: :sale, direcao: :credit, valor: 150)
    lancamento(tipo: :fee, direcao: :debit, valor: 15)

    get "/lancamentos", headers: @cabecalhos

    assert_response :success

    corpo = response.parsed_body

    assert_equal 2, corpo["items"].size
    assert_equal 2, corpo.dig("resumo", "total")
    assert_equal "150.0", corpo.dig("resumo", "creditos").to_s
    assert_equal "15.0", corpo.dig("resumo", "debitos").to_s
  end

  # Os totais são do FILTRO: a pergunta que se faz olhando uma lista filtrada é
  # sobre o que está nela, não sobre o razão inteiro.
  test "filtrar por tipo muda a lista E os totais" do
    lancamento(tipo: :sale, direcao: :credit, valor: 150)
    lancamento(tipo: :fee, direcao: :debit, valor: 15)

    get "/lancamentos", params: { tipo: "fee" }, headers: @cabecalhos

    corpo = response.parsed_body

    assert_equal 1, corpo["items"].size
    assert_equal 1, corpo.dig("resumo", "total")
    assert_equal "0.0", corpo.dig("resumo", "creditos").to_s
  end

  # Procura pelo que a pessoa TEM na mão. Buscar só pelo external_id não
  # serviria: ele é nosso e ninguém o tem anotado em lugar nenhum.
  test "busca encontra pelo pedido e pelo id do pagamento" do
    pedido = criar_pedido(tenant: @tenant, conta: @conta, external_id: "2000017100877708")

    lancamento(tipo: :sale, direcao: :credit, valor: 150, pedido: pedido, pagamento: "PAY-99")
    lancamento(tipo: :settlement, direcao: :debit, valor: 500)

    get "/lancamentos", params: { busca: "2000017100877708" }, headers: @cabecalhos

    assert_equal 1, response.parsed_body["items"].size

    get "/lancamentos", params: { busca: "PAY-99" }, headers: @cabecalhos

    assert_equal 1, response.parsed_body["items"].size
  end

  test "não mostra lançamento de outra empresa" do
    estranha = criar_tenant

    criar_lancamento(tenant: estranha, conta: criar_conta(tenant: estranha), valor: 999)

    lancamento(tipo: :sale, direcao: :credit, valor: 150)

    get "/lancamentos", headers: @cabecalhos

    assert_equal 1, response.parsed_body["items"].size
  end
end
