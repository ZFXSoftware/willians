require "test_helper"

module Conciliacao
  # O bug que este teste existe para não voltar:
  #
  # conciliar é comparar o razão com o OMIE. Como ninguém chamava o ingestor,
  # o razão ficava vazio, e a comparação "OMIE contra nada" terminava como
  # sucesso com `total_entries: 0` — a resposta mais perigosa possível, porque
  # parece que deu certo.
  class IngestaoAntesDeConciliarTest < ActiveSupport::TestCase
    setup do
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant)
    end

    # Sem OMIE de verdade: o que se observa aqui é a ORDEM, não o resultado.
    def conciliar(**args)
      passos = []

      leitura = lambda do |client:, start_date:, end_date:|
        passos << :conciliou

        {}
      end

      ingestao = lambda do
        passos << :buscou

        { contas: 1, sincronizadas: 1, recebidos: 7, novos: 7 }
      end

      resumo = com_metodo(Marketplace::SincronizacaoService, :call, ingestao) do
        com_metodo(ConciliacaoEngine.singleton_class, :carregar_totais, leitura) do
          ConciliacaoService.new(tenant: @tenant, **args).processar
        end
      end

      [ resumo, passos ]
    end

    test "busca do marketplace ANTES de comparar com o OMIE" do
      _, passos = conciliar

      assert_equal %i[buscou conciliou], passos
    end

    test "o resumo carrega o que a busca trouxe" do
      resumo, = conciliar

      assert_equal 7, resumo[:sincronizacao][:novos],
                   "sem isso, ninguém sabe se a conciliação rodou sobre dados novos ou sobre nada"
    end

    test "dá para conciliar sem buscar, quando é isso que se quer" do
      _, passos = conciliar(sincronizar: false)

      assert_equal %i[conciliou], passos
    end

    test "marketplace fora do ar não impede a conferência do que já está no razão" do
      passos = []

      explodir = -> { raise "marketplace fora do ar" }

      leitura = lambda do |client:, start_date:, end_date:|
        passos << :conciliou

        {}
      end

      resumo = com_metodo(Marketplace::SincronizacaoService, :call, explodir) do
        com_metodo(ConciliacaoEngine.singleton_class, :carregar_totais, leitura) do
          ConciliacaoService.new(tenant: @tenant).processar
        end
      end

      assert_equal %i[conciliou], passos, "a conciliação precisa seguir mesmo assim"
      assert_match(/fora do ar/, resumo[:sincronizacao][:erro])
    end
  end
end
