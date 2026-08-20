require "test_helper"

module Conciliacao
  # O disparo agendado chega sem tenant (token de serviço) e varre todas as
  # empresas de uma vez. Cada uma tem o próprio aplicativo no OMIE — se a
  # conciliação usasse uma credencial só, a chave preenchida na tela seria
  # ignorada e o cliente veria "simulação" sem entender por quê.
  class CredenciaisPorEmpresaTest < ActiveSupport::TestCase
    setup do
      @empresa_a = criar_tenant(nome: "Empresa A")
      @empresa_b = criar_tenant(nome: "Empresa B")

      criar_conta(tenant: @empresa_a)
      criar_conta(tenant: @empresa_b)

      configurar(@empresa_a, "chave-da-A", "segredo-da-A")
    end

    def configurar(tenant, chave, segredo)
      IntegrationSetting.create!(tenant: tenant, provider: "omie", key: "app_key", value: chave)
      IntegrationSetting.create!(tenant: tenant, provider: "omie", key: "app_secret", value: segredo)
    end

    # Sem tenant e sem conta: é exatamente como o worker chama.
    def conciliar(&leitura)
      com_env("OMIE_APP_KEY" => nil, "OMIE_APP_SECRET" => nil) do
        com_metodo(ConciliacaoEngine.singleton_class, :carregar_totais, leitura) do
          ConciliacaoService.new(start_date: Date.current - 5, end_date: Date.current).processar
        end
      end
    end

    test "cada empresa é conciliada com a própria credencial" do
      chaves = []

      conciliar do |client:, start_date:, end_date:|
        chaves << (client.is_a?(Omie::Client) ? client.send(:app_key) : :simulacao)

        {}
      end

      assert_includes chaves, "chave-da-A", "a empresa A tem chave própria e deveria usá-la"
      assert_includes chaves, :simulacao, "a empresa B não tem credencial: cai na simulação"
    end

    test "o resumo diz quais empresas rodaram em simulação" do
      resumo = conciliar { |client:, start_date:, end_date:| {} }

      assert resumo[:simulacao], "havendo empresa sem credencial, o resumo precisa avisar"
      assert_equal ["Empresa B"], resumo[:empresas_em_simulacao]
    end

    test "com todas configuradas, nada roda em simulação" do
      configurar(@empresa_b, "chave-da-B", "segredo-da-B")

      resumo = conciliar { |client:, start_date:, end_date:| {} }

      refute resumo[:simulacao]
      assert_empty resumo[:empresas_em_simulacao]
    end

    test "o contexto do tenant não vaza de uma empresa para a outra" do
      vistos = []

      conciliar do |client:, start_date:, end_date:|
        vistos << Current.tenant&.name

        {}
      end

      assert_equal ["Empresa A", "Empresa B"], vistos.sort
      assert_nil Current.tenant, "o contexto precisa ser devolvido ao fim"
    end
  end
end
