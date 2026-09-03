require "test_helper"

module Marketplace
  module MercadoLivre
    # A inferência existe porque o Mercado Livre devolve `pack_id` nulo em boa
    # parte das vendas cuja nota está sob um pacote. Ela é heurística, e o
    # critério de aceitação é ERRO ZERO: um vínculo errado põe a nota da venda A
    # no dinheiro da venda B e não dá sinal nenhum depois.
    class PacoteInferidoTest < ActiveSupport::TestCase
      def setup
        @tenant = criar_tenant
        @conta = criar_conta(tenant: @tenant, plataforma: "mercado_livre")
        @pedido = criar_pedido(tenant: @tenant, conta: @conta, external_id: "PED-1")
        @unidade = criar_recebivel(tenant: @tenant, conta: @conta, pedido: @pedido)
      end

      # Devolve sempre o mesmo comprador.
      class MLFalso
        def initialize(documento) = @documento = documento

        def order_raw(_id) = { "buyer" => { "billing_info" => { "doc_number" => @documento } } }

        def billing_info(_id) = {}
      end

      def inferir(documento: "55788696291")
        PacoteInferido.new(tenant: @tenant, client: MLFalso.new(documento)).para(@unidade.reload)
      end

      def nota_de(comprador:, chave:, pedido:)
        criar_nota(tenant: @tenant, pedido: pedido, numero: "NF-#{chave}", valor: 100).tap do |nota|
          nota.update!(operation_type: :sale,
                       metadata: { "comprador_documento" => comprador, "numero_ecommerce" => chave })
        end
      end

      test "acha o pacote pela nota do comprador" do
        pacote = criar_pedido(tenant: @tenant, conta: @conta, external_id: "PACK-9")

        nota_de(comprador: "557.886.962-91", chave: "PACK-9", pedido: pacote)

        assert_equal "PACK-9", inferir.pack_id
      end

      # O falso positivo que a medição não pegava: ela rodou sobre vendas cuja
      # nota EXISTE, então nunca viu o caso em que a venda não tem nota e o
      # comprador tem uma só, de OUTRA compra. Na população real, dois dos três
      # primeiros palpites eram isso.
      test "não adota a nota de outra venda do mesmo comprador" do
        outra = criar_pedido(tenant: @tenant, conta: @conta, external_id: "PED-2")

        criar_recebivel(tenant: @tenant, conta: @conta, pedido: outra)

        nota_de(comprador: "55788696291", chave: "PED-2", pedido: outra)

        resultado = inferir

        assert_nil resultado.pack_id
        assert_equal :outra_venda, resultado.motivo
      end

      test "comprador com duas notas na janela é descartado, não chutado" do
        pacote = criar_pedido(tenant: @tenant, conta: @conta, external_id: "PACK-9")
        outro = criar_pedido(tenant: @tenant, conta: @conta, external_id: "PACK-8")

        nota_de(comprador: "55788696291", chave: "PACK-9", pedido: pacote)
        nota_de(comprador: "55788696291", chave: "PACK-8", pedido: outro)

        assert_equal :ambiguo, inferir.motivo
      end

      test "sem nota do comprador, não inventa" do
        assert_equal :nenhuma_nota, inferir.motivo
      end

      test "nota já sob o número deste pedido não vira pacote" do
        nota_de(comprador: "55788696291", chave: "PED-1", pedido: @pedido)

        assert_equal :mesma_chave, inferir.motivo
      end

      test "sem documento do comprador, não arrisca" do
        assert_equal :sem_documento, inferir(documento: "").motivo
      end
    end
  end
end
