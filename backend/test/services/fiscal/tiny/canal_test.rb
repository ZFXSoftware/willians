require "test_helper"

module Fiscal
  module Tiny
    # A regra anterior era "só existe uma conta ativa, deve ser essa". Numa
    # amostra de 40 notas do cliente, 23 vieram de outros canais e foram todas
    # atribuídas ao Mercado Livre — 58% das vendas na conciliação errada.
    class CanalTest < ActiveSupport::TestCase
      def setup
        @tenant = criar_tenant
      end

      test "reconhece os canais de nome óbvio" do
        assert_equal "mercado_livre", Canal.para("Mercado Livre")
        assert_equal "shopee", Canal.para("Shopee")
        assert_equal "amazon", Canal.para("Amazon")
        assert_equal "magalu", Canal.para("Magalu")
        assert_equal "tiktok", Canal.para("TikTok")
      end

      # O nome vem digitado por gente, e obrigar a acertar a grafia
      # transformaria a configuração numa armadilha.
      test "grafia não decide o canal" do
        %w[MERCADO\ LIVRE mercado-livre MercadoLivre].each do |escrito|
          assert_equal "mercado_livre", Canal.para(escrito), escrito
        end

        assert_equal "magalu", Canal.para("Magazine Luiza")
      end

      # Nas vendas da Amazon o cliente pôs a própria marca no intermediador.
      # Nenhum padrão poderia adivinhar isso, e é por isso que a tabela é
      # editável por empresa.
      test "a empresa mapeia os nomes que só ela usa" do
        assert_nil Canal.para("Alma teen", tenant: @tenant)

        @tenant.update!(metadata: { Canal::CHAVE => { "Alma teen" => "amazon" } })

        assert_equal "amazon", Canal.para("Alma teen", tenant: @tenant)
      end

      test "a empresa pode corrigir um padrão que não vale para ela" do
        @tenant.update!(metadata: { Canal::CHAVE => { "Shopee" => "magalu" } })

        assert_equal "magalu", Canal.para("Shopee", tenant: @tenant)
      end

      # O ponto do arquivo inteiro: desconhecido devolve nil, e nil não vira
      # palpite. Foi o palpite que pôs 23 notas no canal errado.
      test "nome desconhecido não vira palpite" do
        assert_nil Canal.para("Loja Nova", tenant: @tenant)
        assert_nil Canal.para("")
        assert_nil Canal.para(nil)
      end

      test "lista os nomes que ninguém mapeou ainda" do
        pedido = criar_pedido(tenant: @tenant, conta: criar_conta(tenant: @tenant))

        criar_nota(tenant: @tenant, pedido: pedido, numero: "1", valor: 10)
          .update!(metadata: { "intermediador" => { "nome" => "Alma teen" } })

        criar_nota(tenant: @tenant, pedido: pedido, numero: "2", valor: 10)
          .update!(metadata: { "intermediador" => { "nome" => "Shopee" } })

        assert_equal [ "Alma teen" ], Canal.nao_mapeados(@tenant),
                     "Shopee já é conhecida; só o que falta mapear é trabalho"
      end
    end
  end
end
