require "test_helper"

module Omie
  # Uma empresa no OMIE tem vários clientes, várias contas correntes e plano de
  # contas próprio — e cada marketplace costuma ser um cliente diferente. Se a
  # resolução escorregar, o lançamento vai para a conta errada do cliente.
  class SettingsTest < ActiveSupport::TestCase
    setup do
      @tenant = criar_tenant(metadata: { "omie_cliente_fornecedor_id" => "1111",
                                         "omie_conta_corrente_id" => "2222" })
      @ml = criar_conta(tenant: @tenant, external_id: "demo-ml-001",
                        metadata: { "omie_cliente_fornecedor_id" => "9999",
                                    "omie_conta_corrente_id" => "8888",
                                    "omie_categorias" => { "sale" => "3.01.99" } })
      @shopee = criar_conta(tenant: @tenant, plataforma: "shopee", external_id: "demo-shopee-001")
    end

    def para(conta) = Settings.new(tenant: @tenant, platform_account: conta)

    test "a conta manda; o tenant é o fallback" do
      assert_equal 9999, para(@ml).cliente_fornecedor_id
      assert_equal 8888, para(@ml).conta_corrente_id
      assert_equal 1111, para(@shopee).cliente_fornecedor_id
      assert_equal 2222, para(@shopee).conta_corrente_id
      refute_equal para(@ml).cliente_fornecedor_id, para(@shopee).cliente_fornecedor_id
    end

    test "o diagnóstico diz de onde veio cada valor" do
      assert_equal "platform_account", para(@ml).resolved[:origem_cliente]
      assert_equal "tenant", para(@shopee).resolved[:origem_cliente]
    end

    test "categoria da conta sobrescreve o default, o resto cai no padrão" do
      assert_equal "3.01.99", para(@ml).categoria_para("sale")
      assert_equal "1.02.01", para(@ml).categoria_para("fee")
      assert_equal "1.01.01", para(@shopee).categoria_para("sale")
    end

    test "o payload do OMIE sai com os códigos da conta do lançamento" do
      pedido = criar_pedido(tenant: @tenant, conta: @ml)
      venda = criar_lancamento(tenant: @tenant, conta: @ml, pedido: pedido)

      payload = Mappers::FinancialEntryMapper.new(financial_entry: venda).call

      assert_equal 9999, payload[:codigo_cliente_fornecedor]
      assert_equal 8888, payload[:id_conta_corrente]
      assert_equal "3.01.99", payload[:codigo_categoria]
    end

    test "falta de configuração falha com o caminho para resolver" do
      vazio = criar_tenant

      erro = assert_raises(Settings::MissingConfig) do
        com_env("OMIE_CLIENTE_FORNECEDOR_ID" => nil) do
          Settings.new(tenant: vazio).cliente_fornecedor_id
        end
      end

      # A mensagem mandava "grave em metadata" e citava o nome da chamada da
      # API. Isso servia enquanto configurar era editar o banco; hoje existe
      # tela, e o caminho precisa levar a alguém que não tem acesso ao servidor.
      assert_includes erro.message, "Configurações"
      assert_includes erro.message, "Integrações"
      # E nem para o terminal: a tela ganhou um "Procurar" ao lado do campo,
      # que lista os cadastros do OMIE pelo nome.
      assert_includes erro.message, "Procurar"
      assert_not_includes erro.message, "rake"
    end
  end
end
