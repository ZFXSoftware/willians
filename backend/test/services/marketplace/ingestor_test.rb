require "test_helper"

module Marketplace
  # A simulação existe para desenvolvimento. Em produção ela não pode entrar no
  # lugar de uma conta real e inventar movimentação financeira.
  class IngestorTest < ActiveSupport::TestCase
    setup do
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant)
    end

    def ingerir(conta)
      Ingestors::MarketplaceIngestor.new(
        tenant: @tenant, platform_account: conta,
        start_date: Date.current - 2, end_date: Date.current - 1
      ).call
    end

    test "plataforma sem provider é recusada" do
      magalu = criar_conta(tenant: @tenant, plataforma: "magalu")

      com_env("MARKETPLACE_SIMULATION" => "false") do
        assert_raises(Ingestors::MarketplaceIngestor::UnsupportedPlatform) { ingerir(magalu) }
      end
    end

    test "conta sem credencial é recusada com a simulação desligada" do
      com_env("MARKETPLACE_SIMULATION" => "false") do
        assert_raises(Ingestors::MarketplaceIngestor::MissingCredentials) { ingerir(@conta) }
      end
    end

    test "simulação ligada volta a produzir eventos" do
      magalu = criar_conta(tenant: @tenant, plataforma: "magalu")

      resumo = com_env("MARKETPLACE_SIMULATION" => "true") { ingerir(magalu) }

      assert_operator resumo[:received].to_i, :>, 0
    end

    test "conta conectada usa o provider real, não a simulação" do
      refute Providers::MercadoLivreProvider.configured?(@conta)

      MarketplaceCredential.create!(
        tenant: @tenant, platform_account: @conta, platform: "mercado_livre",
        access_token: "AT-teste", refresh_token: "RT-teste",
        expires_at: 5.hours.from_now, status: :connected
      )

      assert Providers::MercadoLivreProvider.configured?(@conta)

      # O provider real devolve vazio aqui; se a simulação tivesse assumido,
      # viriam eventos inventados.
      resumo = com_metodo(Providers::MercadoLivreProvider, :financial_events,
                          ->(start_date:, end_date:) { [] }) do
        com_env("MARKETPLACE_SIMULATION" => "false") { ingerir(@conta) }
      end

      assert_equal 0, resumo[:received].to_i
    end

    # ------------------------------------------------------- o que o razão grava

    def eventos_de_teste(extras = {})
      [ {
        external_id: "MLREL-1-SALE", source: :mercado_livre, entry_type: :sale,
        direction: :credit, amount: BigDecimal("150"), occurred_at: 1.day.ago,
        external_order_id: "2000000111"
      }.merge(extras) ]
    end

    def ingerir_eventos(extras = {})
      # Precisa da credencial: sem ela o ingestor escolhe o provider de
      # simulação e o dublê abaixo nem chega a ser chamado.
      MarketplaceCredential.find_or_create_by!(platform_account: @conta) do |c|
        c.tenant = @tenant
        c.platform = "mercado_livre"
        c.access_token = "AT-teste"
        c.status = :connected
        c.expires_at = 5.hours.from_now
      end

      # Resolvido FORA do lambda: `com_metodo` o instala como método de
      # instância do provider, então lá dentro `self` já não é o teste.
      eventos = eventos_de_teste(extras)

      com_metodo(Providers::MercadoLivreProvider, :financial_events,
                 ->(start_date:, end_date:) { eventos }) do
        com_env("MARKETPLACE_SIMULATION" => "false") { ingerir(@conta) }
      end
    end

    # O ingestor gravava :pending para TUDO, ignorando o que o provider dizia.
    # O BalanceEngine só soma `settled`, então o extrato de dinheiro já
    # liberado do Mercado Pago deixava o saldo virtual zerado.
    test "o status vem do provider, e não fixo no ingestor" do
      ingerir_eventos(status: :settled, settled_at: 1.day.ago)

      lancamento = FinancialEntry.find_by(external_id: "MLREL-1-SALE")

      assert_equal "settled", lancamento.status
      assert_not_nil lancamento.settled_at
    end

    test "provider que não se pronuncia continua caindo em pendente" do
      ingerir_eventos

      assert_equal "pending", FinancialEntry.find_by(external_id: "MLREL-1-SALE").status
    end

    test "o pedido do marketplace é criado e amarrado ao lançamento" do
      ingerir_eventos

      lancamento = FinancialEntry.find_by(external_id: "MLREL-1-SALE")

      assert_not_nil lancamento.order, "sem o vínculo não há como chegar na NF do Tiny"
      assert_equal "2000000111", lancamento.order.external_id
    end
  end
end
