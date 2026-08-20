require "test_helper"

module Integracoes
  class ConfigTest < ActiveSupport::TestCase
    setup do
      @tenant = criar_tenant
      @outro = criar_tenant
    end

    def gravar(tenant, provedor, chave, valor)
      IntegrationSetting.create!(tenant: tenant, provider: provedor, key: chave.to_s, value: valor)
    end

    test "o que o usuário gravou vence o ambiente" do
      gravar(@tenant, "omie", :app_key, "chave-do-cliente")

      com_env("OMIE_APP_KEY" => "chave-do-ambiente") do
        assert_equal "chave-do-cliente", Config.get("omie", :app_key, tenant: @tenant)
        assert_equal "configuracao", Config.origem("omie", :app_key, tenant: @tenant)
      end
    end

    test "sem configuração, o ambiente ainda vale" do
      com_env("OMIE_APP_KEY" => "chave-do-ambiente") do
        assert_equal "chave-do-ambiente", Config.get("omie", :app_key, tenant: @tenant)
        assert_equal "ambiente", Config.origem("omie", :app_key, tenant: @tenant)
      end
    end

    test "campo sem valor nenhum cai no padrão do catálogo" do
      com_env("SHOPEE_REGION" => nil) do
        assert_equal "br", Config.get("shopee", :region, tenant: @tenant)
        assert_equal "padrao", Config.origem("shopee", :region, tenant: @tenant)
      end
    end

    test "campo obrigatório sem valor é reportado como faltando" do
      com_env("TINY_TOKEN" => nil) do
        assert_nil Config.get("tiny", :token, tenant: @tenant)
        assert_equal "faltando", Config.origem("tiny", :token, tenant: @tenant)
        refute Config.configurado?("tiny", tenant: @tenant)
      end
    end

    test "um tenant não enxerga a chave do outro" do
      gravar(@tenant, "shopee", :partner_key, "chave-A")
      gravar(@outro, "shopee", :partner_key, "chave-B")

      com_env("SHOPEE_PARTNER_KEY" => nil) do
        assert_equal "chave-A", Config.get("shopee", :partner_key, tenant: @tenant)
        assert_equal "chave-B", Config.get("shopee", :partner_key, tenant: @outro)
      end
    end

    test "sem tenant no contexto, só o ambiente responde" do
      gravar(@tenant, "omie", :app_key, "chave-do-cliente")

      com_env("OMIE_APP_KEY" => "chave-do-ambiente") do
        assert_equal "chave-do-ambiente", Config.get("omie", :app_key, tenant: nil)
      end
    end

    test "booleano só aceita valores afirmativos conhecidos" do
      com_env("AMAZON_APP_DRAFT" => nil) do
        gravar(@tenant, "amazon", :app_draft, "true")

        assert Config.bool("amazon", :app_draft, tenant: @tenant)

        # O cast do Rails trataria "nao" como verdadeiro; aqui não.
        IntegrationSetting.find_by!(tenant: @tenant, key: "app_draft").update!(value: "nao")
        Config.limpar_cache

        refute Config.bool("amazon", :app_draft, tenant: @tenant)
      end
    end

    test "configurado? exige todos os campos obrigatórios" do
      com_env("AMAZON_CLIENT_ID" => nil, "AMAZON_CLIENT_SECRET" => nil, "AMAZON_APP_ID" => nil) do
        gravar(@tenant, "amazon", :client_id, "amzn1.x")
        gravar(@tenant, "amazon", :client_secret, "segredo")

        refute Config.configurado?("amazon", tenant: @tenant), "falta o application_id"

        gravar(@tenant, "amazon", :app_id, "amzn1.sp.solution.y")
        Config.limpar_cache

        assert Config.configurado?("amazon", tenant: @tenant)
      end
    end

    test "campo fora do catálogo é erro, não silêncio" do
      assert_raises(ArgumentError) { Config.get("omie", :inventado, tenant: @tenant) }
      assert_raises(ArgumentError) { Config.get("plataforma_inexistente", :x, tenant: @tenant) }
    end

    test "valor não fica em claro no banco" do
      gravar(@tenant, "tiny", :token, "token-secreto-do-tiny")

      bruto = ActiveRecord::Base.connection.select_value(
        "SELECT value FROM integration_settings WHERE tenant_id = #{@tenant.id}"
      ).to_s

      refute_includes bruto, "token-secreto-do-tiny"
      assert bruto.start_with?("{"), "esperado envelope cifrado"
    end

    test "o cliente do OMIE usa a chave do tenant do serviço" do
      gravar(@tenant, "omie", :app_key, "chave-do-tenant")
      gravar(@tenant, "omie", :app_secret, "segredo-do-tenant")

      com_env("OMIE_APP_KEY" => nil, "OMIE_APP_SECRET" => nil) do
        refute Omie::Client.configured?(tenant: @outro)
        assert Omie::Client.configured?(tenant: @tenant)

        cliente = Omie::Client.new(tenant: @tenant)

        assert_equal "chave-do-tenant", cliente.send(:app_key)
      end
    end

    test "o contexto de tenant é restaurado depois do bloco" do
      Current.with_tenant(@tenant) do
        assert_equal @tenant, Current.tenant

        Current.with_tenant(@outro) { assert_equal @outro, Current.tenant }

        assert_equal @tenant, Current.tenant, "o bloco interno não pode vazar"
      end

      assert_nil Current.tenant
    end
  end
end
