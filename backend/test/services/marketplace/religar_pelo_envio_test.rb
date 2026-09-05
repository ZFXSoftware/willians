require "test_helper"

module Marketplace
  # A marca do `NotaDoEnvio` evita repetir a chamada de API. Ela não deveria
  # evitar o pareamento local — e evitava: a nota que chegou do Tiny depois da
  # pergunta ficava solta para sempre.
  class ReligarPeloEnvioTest < ActiveSupport::TestCase
    def setup
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant)
      @pedido = criar_pedido(tenant: @tenant, conta: @conta, external_id: "PED-1")
    end

    def marcar!(chave: nil, numero: "44613", serie: "2")
      @pedido.update!(metadata: (@pedido.metadata || {}).merge(
        "nota_do_envio" => { "chave" => chave, "numero" => numero, "serie" => serie }
      ))
    end

    def religar(dry_run: false)
      MercadoLivre::ReligarPeloEnvio.new(tenant: @tenant, dry_run: dry_run).call
    end

    test "liga a nota que chegou depois da pergunta ao marketplace" do
      marcar!

      nota = criar_nota(tenant: @tenant, pedido: @pedido, numero: "044613", valor: 100)

      nota.update!(series: "2")

      recebivel = criar_recebivel(tenant: @tenant, conta: @conta, pedido: @pedido)

      assert_equal 1, religar[:ligadas]
      assert_equal nota.id, recebivel.reload.invoice_id
    end

    # Ligar cancelada faria esta regra brigar com `soltar_canceladas!`: uma
    # ligando e a outra soltando, a cada ciclo, para sempre.
    test "nota cancelada é deixada solta de propósito" do
      marcar!

      nota = criar_nota(tenant: @tenant, pedido: @pedido, numero: "044613", valor: 100)

      nota.update!(series: "2", status: :cancelled)

      recebivel = criar_recebivel(tenant: @tenant, conta: @conta, pedido: @pedido)

      assert_equal 1, religar[:canceladas]
      assert_equal 0, religar[:ligadas]
      assert_nil recebivel.reload.invoice_id
    end

    # A chave é o dado que o Tiny não trouxe e o marketplace tem.
    test "preenche a chave vazia com a que veio do marketplace" do
      chave = "1" * 44

      marcar!(chave: chave)

      nota = criar_nota(tenant: @tenant, pedido: @pedido, numero: "044613", valor: 100)

      nota.update!(series: "2", access_key: nil)

      criar_recebivel(tenant: @tenant, conta: @conta, pedido: @pedido)

      religar

      assert_equal chave, nota.reload.access_key
    end

    test "não sobrescreve chave já gravada" do
      marcar!(chave: "9" * 44)

      nota = criar_nota(tenant: @tenant, pedido: @pedido, numero: "044613", valor: 100)

      nota.update!(series: "2", access_key: "1" * 44)

      criar_recebivel(tenant: @tenant, conta: @conta, pedido: @pedido)

      religar

      assert_equal "1" * 44, nota.reload.access_key
    end

    test "simulação não grava" do
      marcar!

      nota = criar_nota(tenant: @tenant, pedido: @pedido, numero: "044613", valor: 100)

      nota.update!(series: "2")

      recebivel = criar_recebivel(tenant: @tenant, conta: @conta, pedido: @pedido)

      assert_equal 1, religar(dry_run: true)[:ligadas]
      assert_nil recebivel.reload.invoice_id
    end

    test "pedido sem a marca não é tocado" do
      criar_nota(tenant: @tenant, pedido: @pedido, numero: "044613", valor: 100)

      recebivel = criar_recebivel(tenant: @tenant, conta: @conta, pedido: @pedido)

      assert_equal 0, religar[:ligadas]
      assert_nil recebivel.reload.invoice_id
    end

    # "sem nota no marketplace" é gravado como texto, não como objeto.
    test "marca de venda sem nota no marketplace é ignorada" do
      @pedido.update!(metadata: { "nota_do_envio" => "sem nota no marketplace" })

      criar_recebivel(tenant: @tenant, conta: @conta, pedido: @pedido)

      assert_equal 0, religar[:ligadas]
      assert_equal 0, religar[:sem_nota_aqui]
    end
  end
end
