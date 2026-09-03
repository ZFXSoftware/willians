require "test_helper"

module Marketplace
  # O relatório de liberações do Mercado Pago é gerado de forma assíncrona, e
  # enquanto não fica pronto a ingestão levanta AindaNaoPronto. Isso é espera,
  # não falha — mas a exceção abortava o método inteiro e levava junto o
  # vínculo de pedidos, que NÃO depende do extrato: ele fala com a API de
  # pedidos.
  #
  # Na conta do cliente o relatório ficou pendente por quatro dias. Nesses
  # quatro dias nenhum pedido foi ligado e nenhum `pack_id` foi gravado,
  # travando a nota fiscal de 543 vendas por um motivo sem relação com elas.
  class SincronizacaoPendenteTest < ActiveSupport::TestCase
    def setup
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant, plataforma: "mercado_livre")

      MarketplaceCredential.create!(
        tenant: @tenant, platform_account: @conta, platform: "mercado_livre",
        access_token: "tok", status: :connected, expires_at: 1.day.from_now
      )
    end

    # `AindaNaoPronto` é um MÓDULO marcador, incluído nas exceções de cada
    # plataforma — não dá para levantá-lo direto. O `rescue` casa pelo módulo,
    # que é o ponto: qualquer provider pode sinalizar espera do seu jeito.
    class ExtratoPendente < StandardError
      include AindaNaoPronto
    end

    class IngestorPendente
      def initialize(**) = nil

      def call = raise(ExtratoPendente, "o relatório ainda está sendo gerado")
    end

    class IngestorOk
      def initialize(**) = nil

      def call = { received: 1, created: 1, skipped: 0, failed: 0 }
    end

    class VinculadorEspiao
      def self.chamadas = @chamadas ||= 0

      def self.registrar! = @chamadas = chamadas + 1

      def self.zerar! = @chamadas = 0

      def initialize(**) = nil

      def call
        self.class.registrar!

        { pedidos: 3, lancamentos_ligados: 2 }
      end
    end

    def sincronizar(ingestor)
      VinculadorEspiao.zerar!

      SincronizacaoService.new(
        tenant: @tenant, platform_account: @conta, forcar: true,
        start_date: Date.current - 7, end_date: Date.current,
        ingestor: ingestor, vinculador: VinculadorEspiao
      ).call
    end

    test "extrato pendente não impede o vínculo de pedidos" do
      sincronizar(IngestorPendente)

      assert_equal 1, VinculadorEspiao.chamadas,
                   "o vínculo usa a API de PEDIDOS, que está no ar mesmo com o extrato pendente"
    end

    # Espera não pode virar sucesso: o extrato continua sem chegar, e marcar
    # "ok" faria a tela dizer "importação concluída — 0 lançamentos".
    test "extrato pendente continua marcando a conta como pendente" do
      sincronizar(IngestorPendente)

      assert_equal "pendente", @conta.reload.last_sync_status
    end

    test "com o extrato pronto, o vínculo roda uma vez só" do
      sincronizar(IngestorOk)

      assert_equal 1, VinculadorEspiao.chamadas
      assert_equal "ok", @conta.reload.last_sync_status
    end
  end
end
