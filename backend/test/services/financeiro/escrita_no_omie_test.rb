require "test_helper"

module Financeiro
  # Numa instalação multiempresa cada cliente traz a própria conta do OMIE, e
  # o .env do servidor fica vazio. Duas coisas precisam valer nesse cenário:
  #
  #   1. preencher a tela tem que ser suficiente;
  #   2. NÃO preencher não pode parecer que funcionou.
  #
  # O segundo é o perigoso: sem credencial o sistema cai no cliente de
  # simulação, e um serviço de escrita rodando contra o dublê registraria
  # baixas e reportaria sucesso sem nada ter acontecido no ERP.
  class EscritaNoOmieTest < ActiveSupport::TestCase
    setup do
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant, metadata: {
        "omie_conta_corrente_id" => "6455415244",
        "omie_conta_corrente_destino_id" => "12557610062"
      })
    end

    def sem_credencial_no_servidor(&bloco)
      com_env("OMIE_APP_KEY" => nil, "OMIE_APP_SECRET" => nil, "OMIE_ALLOW_WRITES" => "true", &bloco)
    end

    def credencial_pela_tela
      IntegrationSetting.create!(tenant: @tenant, provider: "omie", key: "app_key", value: "K")
      IntegrationSetting.create!(tenant: @tenant, provider: "omie", key: "app_secret", value: "S")
      Integracoes::Config.limpar_cache
    end

    def saque
      criar_lancamento(tenant: @tenant, conta: @conta, tipo: :settlement, direcao: :debit,
                       valor: 1000, ocorrido_em: 2.days.ago)
    end

    test "sem credencial nenhuma, a escrita é simulada mesmo com OMIE_ALLOW_WRITES ligado" do
      lancamento = saque

      resumo = sem_credencial_no_servidor do
        TransferenciaEntreContas.new(tenant: @tenant).call[:resumo]
      end

      assert resumo[:simulacao], "sem credencial não pode executar de verdade"
      assert_equal :sem_credencial, resumo[:motivo_da_simulacao]
      assert_includes resumo[:aviso], "Configurações"

      # O ponto: nada pode ter sido registrado como sincronizado.
      assert_nil OmieFinancialMapping.find_by(financial_entry_id: lancamento.id)
    end

    test "com a credencial preenchida na tela, a escrita deixa de ser simulada" do
      saque
      credencial_pela_tela

      espiao = OmieEspiao.new

      resumo = sem_credencial_no_servidor do
        TransferenciaEntreContas.new(tenant: @tenant, client: espiao).call[:resumo]
      end

      refute resumo[:simulacao], "credencial da empresa deveria liberar a execução"
      assert_equal 1, espiao.chamadas.size
    end

    test "escrita bloqueada é distinguida de falta de credencial" do
      saque
      credencial_pela_tela

      resumo = com_env("OMIE_ALLOW_WRITES" => nil) do
        TransferenciaEntreContas.new(tenant: @tenant, client: OmieEspiao.new).call[:resumo]
      end

      assert resumo[:simulacao]
      assert_equal :escrita_bloqueada, resumo[:motivo_da_simulacao],
                   "aqui há credencial; o que falta é a liberação no servidor"
      # O resumo tem default 0, então a chave ausente não é nil.
      refute resumo.key?(:aviso), "o aviso é só para o caso de falta de credencial"
    end

    test "todos os serviços de escrita respeitam a mesma regra" do
      pedido = criar_pedido(tenant: @tenant, conta: @conta)
      nota = criar_nota(tenant: @tenant, pedido: pedido, numero: "000900001", valor: 100)
      criar_lancamento(tenant: @tenant, conta: @conta, tipo: :fee, direcao: :debit,
                       valor: 50, ocorrido_em: 2.days.ago, status: :pending)
      criar_lancamento(tenant: @tenant, conta: @conta, tipo: :payment, direcao: :debit,
                       valor: 100, pedido: pedido, nota: nota, ocorrido_em: 2.days.ago)
      criar_recebivel(tenant: @tenant, conta: @conta, pedido: pedido, nota: nota,
                      previsto_para: Date.current + 7)
      saque

      @conta.update!(metadata: @conta.metadata.merge(
        "omie_categoria_transitoria_receita" => "1.04",
        "omie_categoria_transitoria_despesa" => "2.02.95",
        "omie_cliente_fornecedor_id" => "12558825674"
      ))

      servicos = {
        "transferências" => -> { TransferenciaEntreContas.new(tenant: @tenant).call },
        "valores não vinculados" => -> { ValoresNaoVinculados.new(tenant: @tenant, start_date: Date.current - 10, end_date: Date.current).call },
        "previsão" => -> { PrevisaoDeRecebimento.new(tenant: @tenant, titulos: {}).call },
        "pagamentos" => -> { BaixaDePagamentos.new(tenant: @tenant, titulos: {}).call }
      }

      sem_credencial_no_servidor do
        servicos.each do |nome, executar|
          resumo = executar.call[:resumo]

          assert resumo[:simulacao], "#{nome}: deveria simular sem credencial"
          assert_equal :sem_credencial, resumo[:motivo_da_simulacao], nome
        end
      end

      assert_equal 0, OmieFinancialMapping.where(tenant_id: @tenant.id).count,
                   "nenhum serviço pode registrar sincronização contra o dublê"
    end
  end
end
