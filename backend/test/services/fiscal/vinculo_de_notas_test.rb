require "test_helper"

module Fiscal
  # A ordem natural dos fatos derrubava o vínculo: a nota é emitida no dia da
  # venda, o dinheiro do marketplace chega duas semanas depois, e quem ligava
  # os dois só rodava na hora de importar a nota.
  class VinculoDeNotasTest < ActiveSupport::TestCase
    def setup
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant)
      @pedido = criar_pedido(tenant: @tenant, conta: @conta, external_id: "PED-1")
    end

    def religar = VinculoDeNotas.new(tenant: @tenant).call

    # O caso que representa 176 vendas da base do cliente: a nota estava lá, o
    # pedido batia, e o recebível continuava sem nota.
    test "recebível criado depois da nota é religado" do
      nota = criar_nota(tenant: @tenant, pedido: @pedido, numero: "111", valor: 100)

      nota.update!(operation_type: :sale)

      recebivel = criar_recebivel(tenant: @tenant, conta: @conta, pedido: @pedido)

      assert_nil recebivel.invoice_id

      assert_equal 1, religar[:recebiveis]
      assert_equal nota.id, recebivel.reload.invoice_id
    end

    test "lançamento também é religado" do
      nota = criar_nota(tenant: @tenant, pedido: @pedido, numero: "111", valor: 100)

      nota.update!(operation_type: :sale)

      lancamento = criar_lancamento(tenant: @tenant, conta: @conta, pedido: @pedido, valor: 100)

      assert_equal 1, religar[:lancamentos]
      assert_equal nota.id, lancamento.reload.invoice_id
    end

    # Nota de devolução não é o documento da venda: ligá-la ao recebível faria
    # a conciliação procurar o título errado no OMIE.
    test "nota de devolução não é usada" do
      criar_nota(tenant: @tenant, pedido: @pedido, numero: "999", valor: 100)
        .update!(operation_type: :refund)

      recebivel = criar_recebivel(tenant: @tenant, conta: @conta, pedido: @pedido)

      assert_equal 0, religar[:recebiveis]
      assert_nil recebivel.reload.invoice_id
    end

    test "nota cancelada não é usada" do
      criar_nota(tenant: @tenant, pedido: @pedido, numero: "999", valor: 100)
        .update!(operation_type: :sale, status: :cancelled)

      recebivel = criar_recebivel(tenant: @tenant, conta: @conta, pedido: @pedido)

      assert_equal 0, religar[:recebiveis]
    end

    # Um pedido pode ter mais de uma nota (complementar, reemissão). Pegar
    # qualquer uma faria o mesmo pedido casar com títulos diferentes conforme a
    # ordem em que o banco devolvesse as linhas.
    test "com mais de uma nota no pedido, usa a mais antiga" do
      antiga = criar_nota(tenant: @tenant, pedido: @pedido, numero: "111", valor: 100)
      antiga.update!(operation_type: :sale, issued_at: Date.current - 10)

      nova = criar_nota(tenant: @tenant, pedido: @pedido, numero: "222", valor: 20)
      nova.update!(operation_type: :sale, issued_at: Date.current)

      recebivel = criar_recebivel(tenant: @tenant, conta: @conta, pedido: @pedido)

      religar

      assert_equal antiga.id, recebivel.reload.invoice_id
      assert_not_equal nova.id, recebivel.invoice_id
    end

    # Roda a cada volta do ciclo: não pode ficar reescrevendo o que já está
    # ligado, nem trocar um vínculo que alguém corrigiu à mão.
    test "não mexe no que já está ligado" do
      outra = criar_nota(tenant: @tenant, pedido: @pedido, numero: "333", valor: 50)
      outra.update!(operation_type: :sale)

      recebivel = criar_recebivel(tenant: @tenant, conta: @conta, pedido: @pedido, nota: outra)

      assert_equal 0, religar[:recebiveis]
      assert_equal outra.id, recebivel.reload.invoice_id
    end

    # Compra com mais de um item: o Mercado Livre cria um "pack" com id
    # próprio, a nota é emitida para o PACOTE, e o extrato fala do pedido
    # individual. Sem cruzar os dois, a venda fica sem nota para sempre — eram
    # 543 na base do cliente.
    test "venda de um pacote encontra a nota emitida para o pacote" do
      pacote = criar_pedido(tenant: @tenant, conta: @conta, external_id: "PACK-9")

      nota = criar_nota(tenant: @tenant, pedido: pacote, numero: "777", valor: 300)

      nota.update!(operation_type: :sale)

      @pedido.update!(metadata: (@pedido.metadata || {}).merge("pack_id" => "PACK-9"))

      recebivel = criar_recebivel(tenant: @tenant, conta: @conta, pedido: @pedido)

      assert_equal 1, religar[:por_pacote]
      assert_equal nota.id, recebivel.reload.invoice_id
    end

    test "pedido sem pacote não puxa nota de ninguém" do
      outro = criar_pedido(tenant: @tenant, conta: @conta, external_id: "OUTRO-9")

      criar_nota(tenant: @tenant, pedido: outro, numero: "888", valor: 300)
        .update!(operation_type: :sale)

      recebivel = criar_recebivel(tenant: @tenant, conta: @conta, pedido: @pedido)

      assert_equal 0, religar[:por_pacote]
      assert_nil recebivel.reload.invoice_id
    end

    # Nota cancelada continuava grudada na venda: o envio ao OMIE a ignorava
    # (certo) e a conciliação seguia esperando um título que nunca viria,
    # contando a venda como "sem título" e inchando a diferença.
    test "nota cancelada é solta da venda" do
      cancelada = criar_nota(tenant: @tenant, pedido: @pedido, numero: "999", valor: 100)
      cancelada.update!(operation_type: :sale, status: :cancelled)

      recebivel = criar_recebivel(tenant: @tenant, conta: @conta, pedido: @pedido, nota: cancelada)

      religar

      assert_nil recebivel.reload.invoice_id
    end

    # E, solta, ela dá lugar à substituta — que é o motivo de soltar.
    test "a venda passa a apontar para a nota que substituiu a cancelada" do
      cancelada = criar_nota(tenant: @tenant, pedido: @pedido, numero: "999", valor: 100)
      cancelada.update!(operation_type: :sale, status: :cancelled)

      nova = criar_nota(tenant: @tenant, pedido: @pedido, numero: "1000", valor: 100)
      nova.update!(operation_type: :sale)

      recebivel = criar_recebivel(tenant: @tenant, conta: @conta, pedido: @pedido, nota: cancelada)

      religar

      assert_equal nova.id, recebivel.reload.invoice_id
    end

    test "não atravessa empresas" do
      outra_empresa = criar_tenant

      criar_nota(tenant: @tenant, pedido: @pedido, numero: "111", valor: 100)
        .update!(operation_type: :sale)

      recebivel = criar_recebivel(tenant: @tenant, conta: @conta, pedido: @pedido)

      assert_equal 0, VinculoDeNotas.new(tenant: outra_empresa).call[:recebiveis]
      assert_nil recebivel.reload.invoice_id
    end
  end
end
