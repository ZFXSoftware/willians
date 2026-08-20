require "test_helper"

module Financeiro
  # Briefing 2.6: crédito ou débito que cai na conta sem pedido e sem nota
  # fiscal precisa virar lançamento numa categoria transitória, para que o
  # extrato do OMIE feche com o do marketplace.
  class ValoresNaoVinculadosTest < ActiveSupport::TestCase
    CATEGORIAS = {
      "omie_cliente_fornecedor_id" => "12558825674",
      "omie_conta_corrente_id" => "6455415244",
      "omie_categoria_transitoria_receita" => "1.04",
      "omie_categoria_transitoria_despesa" => "2.02.95"
    }.freeze

    setup do
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant, metadata: CATEGORIAS.dup)
      @de = Date.current - 10
      @ate = Date.current

      @taxa = criar_lancamento(tenant: @tenant, conta: @conta, external_id: "NV-TAXA",
                               tipo: :fee, direcao: :debit, valor: 86.40,
                               ocorrido_em: Date.current - 2, status: :pending)
      @credito = criar_lancamento(tenant: @tenant, conta: @conta, external_id: "NV-CREDITO",
                                  tipo: :adjustment, direcao: :credit, valor: 42.10,
                                  ocorrido_em: Date.current - 2, status: :pending)
      # Liquidação é o repasse em si, não uma cobrança nova.
      criar_lancamento(tenant: @tenant, conta: @conta, external_id: "NV-SETTLE",
                       tipo: :settlement, direcao: :credit, valor: 500.00,
                       ocorrido_em: Date.current - 2, status: :pending)
      criar_lancamento(tenant: @tenant, conta: @conta, external_id: "NV-VINCULADA",
                       tipo: :fee, direcao: :debit, valor: 10.0,
                       pedido: criar_pedido(tenant: @tenant, conta: @conta),
                       ocorrido_em: Date.current - 2, status: :pending)
    end

    def rodar(client:, **opcoes)
      ValoresNaoVinculados.new(tenant: @tenant, start_date: @de, end_date: @ate,
                               client: client, **opcoes).call
    end

    test "seleciona só o que não tem pedido nem nota" do
      espiao = OmieEspiao.new
      resultado = rodar(client: espiao)

      assert resultado[:resumo][:simulacao], "simulação é o padrão"
      assert_empty espiao.chamadas

      ids = resultado[:detalhes].map { |d| d[:external_id] }

      assert_includes ids, "NV-TAXA"
      assert_includes ids, "NV-CREDITO"
      refute_includes ids, "NV-VINCULADA", "tem pedido, não é valor solto"
      refute_includes ids, "NV-SETTLE", "liquidação não é cobrança nova"
    end

    test "débito vira conta a pagar e crédito conta a receber" do
      espiao = OmieEspiao.new
      resultado = rodar(client: espiao, dry_run: false)

      assert_equal 2, resultado[:resumo][:lancados]

      pagar = espiao.chamadas.find { |c| c[:call] == "IncluirContaPagar" }
      receber = espiao.chamadas.find { |c| c[:call] == "IncluirContaReceber" }

      assert pagar, "débito deveria virar conta a pagar"
      assert receber, "crédito deveria virar conta a receber"
      assert_equal "financas/contapagar/", pagar[:endpoint]
      assert_equal "2.02.95", pagar[:params][:codigo_categoria]
      assert_equal "1.04", receber[:params][:codigo_categoria]
      assert_equal 86.4, pagar[:params][:valor_documento]
    end

    test "payload traz todos os campos obrigatórios do OMIE" do
      espiao = OmieEspiao.new
      rodar(client: espiao, dry_run: false)

      params = espiao.params_de("IncluirContaPagar").first

      %i[codigo_lancamento_integracao codigo_cliente_fornecedor data_vencimento
         valor_documento codigo_categoria data_previsao id_conta_corrente].each do |campo|
        assert params.key?(campo), "faltou #{campo}"
      end
    end

    test "identificador usa prefixo próprio para não colidir com o TrackCash" do
      espiao = OmieEspiao.new
      rodar(client: espiao, dry_run: false)

      identificador = espiao.params_de("IncluirContaPagar").first[:codigo_lancamento_integracao]

      assert identificador.start_with?("WLL-"), identificador
    end

    test "grava rastro e não relança o que já foi enviado" do
      rodar(client: OmieEspiao.new, dry_run: false)

      mapeamento = OmieFinancialMapping.find_by(financial_entry_id: @taxa.id)

      assert mapeamento&.synced?
      assert_equal "2.02.95", mapeamento.omie_category_id

      segunda = OmieEspiao.new
      resumo = rodar(client: segunda, dry_run: false)[:resumo]

      assert_equal 0, resumo[:encontrados].to_i
      assert_empty segunda.chamadas, "reexecução não pode duplicar lançamento"
    end

    test "sem categoria transitória configurada, falha com mensagem útil" do
      @conta.update!(metadata: @conta.metadata.except("omie_categoria_transitoria_despesa"))

      erro = assert_raises(ValoresNaoVinculados::ConfiguracaoAusente) do
        com_env("OMIE_CATEGORIA_TRANSITORIA_DESPESA" => nil) do
          rodar(client: OmieEspiao.new, dry_run: false)
        end
      end

      assert_match(/transitoria_despesa/, erro.message)
    end
  end
end
