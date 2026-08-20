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
  end
end
