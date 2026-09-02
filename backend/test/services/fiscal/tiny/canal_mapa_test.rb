require "test_helper"

module Fiscal
  module Tiny
    # O mapa de canais é a lista de trabalho de quem opera: o sistema descobre
    # os nomes nas notas, e uma pessoa diz o que cada um é.
    class CanalMapaTest < ActiveSupport::TestCase
      def setup
        @tenant = criar_tenant
        @conta = criar_conta(tenant: @tenant)
        @pedido = criar_pedido(tenant: @tenant, conta: @conta, external_id: "P-1")
      end

      def nota_de(intermediador, numero:)
        criar_nota(tenant: @tenant, pedido: @pedido, numero: numero, valor: 10)
          .update!(metadata: { "intermediador" => { "nome" => intermediador, "cnpj" => "00" } })
      end

      test "lista os nomes encontrados, com quantas notas e para onde vão" do
        2.times { |i| nota_de("Shopee", numero: "S#{i}") }
        nota_de("Alma teen", numero: "A0")

        encontrados = Canal.encontrados(@tenant)

        shopee = encontrados.find { |e| e[:nome] == "Shopee" }
        alma = encontrados.find { |e| e[:nome] == "Alma teen" }

        assert_equal 2, shopee[:notas]
        assert_equal "shopee", shopee[:canal]
        assert_nil alma[:canal], "ninguém adivinha o que é 'Alma teen'"
      end

      # O que falta mapear vem primeiro: é o que impede as notas de virarem
      # pedido, e o que a pessoa precisa resolver.
      test "o que falta mapear aparece antes do que já está resolvido" do
        3.times { |i| nota_de("Shopee", numero: "S#{i}") }
        nota_de("Alma teen", numero: "A0")

        assert_equal "Alma teen", Canal.encontrados(@tenant).first[:nome]
      end

      # Venda de balcão emitida como digital por exigência fiscal. Não é
      # marketplace, não tem repasse de ninguém, e precisa ser distinguível de
      # "nome que ninguém mapeou ainda".
      test "venda própria é canal, e não é marketplace" do
        Canal.mapear!(@tenant, "Alma teen", Canal::PROPRIA)

        assert_equal Canal::PROPRIA, Canal.para("Alma teen", tenant: @tenant.reload)
        assert_not Canal.marketplace?(Canal::PROPRIA)
        assert Canal.marketplace?("shopee")
      end

      test "canal em branco desfaz o mapeamento" do
        Canal.mapear!(@tenant, "Alma teen", Canal::PROPRIA)
        Canal.mapear!(@tenant, "Alma teen", "")

        assert_nil Canal.para("Alma teen", tenant: @tenant.reload)
      end

      # Gravar um canal inventado poria as notas numa plataforma que não existe
      # em lugar nenhum do sistema — e ninguém veria até a conciliação não achar
      # nada.
      test "canal fora da lista é recusado" do
        assert_raises(ArgumentError) { Canal.mapear!(@tenant, "Alma teen", "shoppe") }
      end

      test "mapear um nome não afeta os outros" do
        Canal.mapear!(@tenant, "Alma teen", Canal::PROPRIA)
        Canal.mapear!(@tenant, "Loja B", "magalu")

        assert_equal Canal::PROPRIA, Canal.para("Alma teen", tenant: @tenant.reload)
        assert_equal "magalu", Canal.para("Loja B", tenant: @tenant)
      end
    end
  end
end
