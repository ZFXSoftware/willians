require "test_helper"

module Marketplace
  # O elo pedido ↔ pagamento era um `return unless conta.mercado_livre?`
  # escondido dentro do serviço de sincronização.
  #
  # Certo no efeito — só o Mercado Livre precisa — e péssimo como forma: no dia
  # em que a Shopee fosse conectada, os lançamentos dela entrariam e nada seria
  # vinculado, em silêncio, e pareceria defeito novo quando era ausência
  # conhecida.
  #
  # Como contrato, cada plataforma responde por si, e a resposta é verificável.
  class ContratoDoProviderTest < ActiveSupport::TestCase
    PROVIDERS = Ingestors::MarketplaceIngestor::PROVIDERS

    test "toda plataforma suportada declara se precisa de vínculo de pedidos" do
      PROVIDERS.each do |plataforma, nome|
        classe = nome.constantize

        assert_includes [ true, false ], classe.vincula_pedidos?,
                        "#{plataforma} precisa responder vincula_pedidos?"
      end
    end

    # Só o Mercado Livre: o relatório de liberações identifica cada linha pelo
    # PAGAMENTO e deixa a coluna do pedido vazia. Shopee traz o order_sn no
    # escrow e Amazon traz o pedido no evento financeiro — para elas a ingestão
    # já liga sozinha.
    test "só o Mercado Livre precisa do passo de vínculo" do
      precisam = PROVIDERS.select { |_, nome| nome.constantize.vincula_pedidos? }.keys

      assert_equal [ "mercado_livre" ], precisam
    end

    # Quem diz que precisa é obrigado a saber buscar pedidos. Sem isto, um
    # provider poderia declarar `true` e não implementar nada — voltando ao
    # silêncio, agora com contrato.
    test "quem declara que precisa implementa a busca de pedidos" do
      PROVIDERS.each_value do |nome|
        classe = nome.constantize

        next unless classe.vincula_pedidos?

        assert classe.instance_method(:orders).owner != Providers::BaseProvider,
               "#{classe} declara vincula_pedidos? mas não implementa #orders"
      end
    end

    test "quem não precisa recebe erro claro se alguém chamar orders" do
      conta = criar_conta(tenant: criar_tenant, plataforma: "shopee")

      erro = assert_raises(NotImplementedError) do
        Providers::ShopeeProvider.new(account: conta).orders(
          start_date: Date.current - 7, end_date: Date.current
        )
      end

      assert_match(/não implementa/, erro.message)
    end

    # Agrupamento fiscal é outra capacidade, e só o Mercado Livre tem: a nota
    # do "pack" cobre várias vendas.
    test "só o Mercado Livre agrupa pedidos para efeito fiscal" do
      agrupam = PROVIDERS.select { |_, nome| nome.constantize.agrupa_pedidos? }.keys

      assert_equal [ "mercado_livre" ], agrupam
    end
  end
end
