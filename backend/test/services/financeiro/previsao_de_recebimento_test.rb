require "test_helper"

module Financeiro
  # Briefing 2.3: a data prevista de recebimento do marketplace tem que chegar
  # ao título no OMIE, senão o fluxo de caixa do cliente fica errado.
  class PrevisaoDeRecebimentoTest < ActiveSupport::TestCase
    setup do
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant)
      @futuro = Date.current + 14

      @desatualizado = montar("PED-PREV-1", "000900001")
      @ja_correto = montar("PED-PREV-2", "000900002")
      @sem_titulo = montar("PED-PREV-3", "000900003")

      @indice = TitulosFalsos.indice(
        # Previsão de hoje no OMIE, mas o marketplace diz que cai em 14 dias.
        TitulosFalsos.titulo(codigo: 901, numero: "900001", valor: 100,
                             previsao: Date.current.strftime("%d/%m/%Y")),
        TitulosFalsos.titulo(codigo: 902, numero: "900002", valor: 100,
                             previsao: @futuro.strftime("%d/%m/%Y"))
      )
    end

    def montar(referencia, numero_nf)
      pedido = criar_pedido(tenant: @tenant, conta: @conta, external_id: referencia)
      nota = criar_nota(tenant: @tenant, pedido: pedido, numero: numero_nf)

      criar_recebivel(tenant: @tenant, conta: @conta, pedido: pedido, nota: nota,
                      previsto_para: @futuro)
    end

    def rodar(client:, **opcoes)
      PrevisaoDeRecebimento.new(tenant: @tenant, client: client, titulos: @indice, **opcoes).call
    end

    test "simulação classifica sem tocar no OMIE" do
      espiao = OmieEspiao.new
      resumo = rodar(client: espiao)[:resumo]

      assert resumo[:simulacao]
      assert_empty espiao.chamadas
      assert_equal 1, resumo[:atualizaria]
      assert_equal 1, resumo[:ja_corretos]
      assert_equal 1, resumo[:sem_titulo]
    end

    test "altera só o título desatualizado, com payload mínimo" do
      espiao = OmieEspiao.new
      resumo = rodar(client: espiao, dry_run: false)[:resumo]

      assert_equal 1, resumo[:atualizados]
      assert_equal 1, espiao.chamadas.size
      assert_equal "AlterarContaReceber", espiao.chamadas.first[:call]

      params = espiao.chamadas.first[:params]

      assert_equal 901, params[:codigo_lancamento_omie]
      assert_equal @futuro.strftime("%d/%m/%Y"), params[:data_previsao]
      # Payload mínimo é proposital: AlterarContaReceber sobrescreve o que
      # receber, então mandar campo a mais apagaria dado do cliente.
      assert_equal %i[codigo_lancamento_omie data_previsao], params.keys.sort
    end

    test "limite interrompe o lote para validação em um título" do
      @indice.merge!(TitulosFalsos.indice(
        TitulosFalsos.titulo(codigo: 903, numero: "900003", valor: 100,
                             previsao: Date.current.strftime("%d/%m/%Y"))
      ))

      espiao = OmieEspiao.new
      rodar(client: espiao, dry_run: false, limite: 1)

      assert_equal 1, espiao.chamadas.size
    end

    test "recebível já pago não entra no lote" do
      @desatualizado.update!(status: :paid)

      assert_equal 2, rodar(client: OmieEspiao.new)[:resumo][:recebiveis]
    end
  end
end
