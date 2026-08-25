require "test_helper"

module Marketplace
  # O elo que faltava: conectar uma conta não trazia nada, porque ninguém
  # chamava o ingestor. Estes testes prendem o comportamento novo — sobretudo
  # o que ele se RECUSA a fazer.
  class SincronizacaoServiceTest < ActiveSupport::TestCase
    def setup
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant, plataforma: "mercado_livre")
    end

    def conectar!(conta = @conta)
      MarketplaceCredential.create!(
        tenant: conta.tenant,
        platform_account: conta,
        platform: conta.platform,
        status: :connected,
        access_token: "token-de-teste",
        expires_at: 4.hours.from_now
      )
    end

    # Substitui o ingestor inteiro: aqui o que importa é a orquestração, não a
    # ingestão em si — que tem os testes dela.
    def com_ingestor(resumo: { received: 3, created: 2, skipped: 1, failed: 0 }, &bloco)
      chamadas = []

      corpo = lambda do
        chamadas << platform_account.id

        raise resumo if resumo.is_a?(StandardError)

        resumo
      end

      com_metodo(Ingestors::MarketplaceIngestor, :call, corpo) do
        bloco.call(chamadas)
      end
    end

    def sincronizar(**args)
      SincronizacaoService.new(tenant: @tenant, **args).call
    end

    # ------------------------------------------------- o caminho que funciona

    test "traz os eventos da conta conectada e conta o que entrou" do
      conectar!

      resumo = com_ingestor { |_| sincronizar }

      assert_equal 1, resumo[:sincronizadas]
      assert_equal 3, resumo[:recebidos]
      assert_equal 2, resumo[:novos]
    end

    test "marca a tentativa mesmo quando não veio nada" do
      conectar!

      com_ingestor(resumo: { received: 0 }) { |_| sincronizar }

      # Sem este carimbo o agendador varreria o marketplace a cada 5 minutos
      # para sempre, já que nenhum lançamento novo mudaria o "último evento".
      assert_not_nil @conta.reload.last_synced_at
      assert_nil @conta.last_sync_error
    end

    # ------------------------------------------- o que ele se recusa a fazer

    test "conta não conectada é ignorada, não sincronizada" do
      resumo = com_ingestor { |chamadas| [ sincronizar, chamadas ] }

      resultado, chamadas = resumo

      assert_empty chamadas, "não pode chamar o ingestor sem credencial"
      assert_equal 1, resultado[:ignoradas]
      assert_match(/não conectada/, resultado[:detalhes].first[:motivo])
    end

    test "não sincroniza de novo dentro do intervalo mínimo" do
      conectar!

      @conta.update_columns(last_synced_at: 5.minutes.ago)

      resultado, chamadas = com_ingestor { |c| [ sincronizar, c ] }

      assert_empty chamadas
      assert_equal 1, resultado[:ignoradas]
    end

    test "o intervalo mínimo cede quando o usuário pede na mão" do
      conectar!

      @conta.update_columns(last_synced_at: 5.minutes.ago)

      resultado, chamadas = com_ingestor { |c| [ sincronizar(forcar: true), c ] }

      assert_equal [ @conta.id ], chamadas
      assert_equal 1, resultado[:sincronizadas]
    end

    test "passado o intervalo, volta a sincronizar sozinho" do
      conectar!

      @conta.update_columns(last_synced_at: 2.hours.ago)

      _, chamadas = com_ingestor { |c| [ sincronizar, c ] }

      assert_equal [ @conta.id ], chamadas
    end

    # ------------------------------------------------------------- as falhas

    test "falha de uma conta não derruba as outras" do
      conectar!

      outra = criar_conta(tenant: @tenant, plataforma: "shopee")

      conectar!(outra)

      chamadas = []

      corpo = lambda do
        chamadas << platform_account.id

        raise "token expirado" if platform_account.platform == "mercado_livre"

        { received: 1, created: 1 }
      end

      resultado = com_metodo(Ingestors::MarketplaceIngestor, :call, corpo) { sincronizar }

      assert_equal 2, chamadas.size, "a segunda conta precisa ser tentada mesmo assim"
      assert_equal 1, resultado[:falhas]
      assert_equal 1, resultado[:sincronizadas]
    end

    test "a falha fica gravada na conta, e não só no log" do
      conectar!

      com_ingestor(resumo: RuntimeError.new("token expirado")) { |_| sincronizar }

      @conta.reload

      assert_match(/token expirado/, @conta.last_sync_error)

      # Carimba a tentativa junto com o erro: sem isso uma credencial quebrada
      # seria retentada de 5 em 5 minutos, indefinidamente.
      assert_not_nil @conta.last_synced_at
    end

    # ------------------------------------------- nem sucesso, nem falha

    # O caso que produziu "importação concluída — 0 lançamento(s) no total"
    # para uma importação que não aconteceu: o relatório do Mercado Pago é
    # gerado de forma assíncrona, e a espera vinha virando lista vazia.
    test "marketplace ainda preparando o dado não conta como sincronizada" do
      conectar!

      pendente = Marketplace::MercadoLivre::ReleasesClient::ReportPending.new("ainda gerando")

      resumo = com_ingestor(resumo: pendente) { |_| sincronizar }

      assert_equal 0, resumo[:sincronizadas]
      assert_equal 0, resumo[:falhas]
      assert_equal 1, resumo[:pendentes]
      assert_equal :pendente, resumo[:detalhes].first[:status]
    end

    test "a espera fica gravada na conta, sem virar erro" do
      conectar!

      pendente = Marketplace::MercadoLivre::ReleasesClient::ReportPending.new("ainda gerando")

      com_ingestor(resumo: pendente) { |_| sincronizar }

      @conta.reload

      assert_equal "pendente", @conta.last_sync_status
      assert_match(/ainda gerando/, @conta.last_sync_error)

      # Carimba a tentativa: o agendador roda de 5 em 5 minutos, e mandar
      # gerar o mesmo relatório a cada volta é abuso da API do outro lado.
      assert_not_nil @conta.last_synced_at
    end

    test "sucesso e falha também ficam marcados" do
      conectar!

      com_ingestor { |_| sincronizar }

      assert_equal "ok", @conta.reload.last_sync_status

      com_ingestor(resumo: RuntimeError.new("caiu")) { |_| sincronizar(forcar: true) }

      assert_equal "falha", @conta.reload.last_sync_status
    end

    test "o erro anterior some quando a sincronização volta a funcionar" do
      conectar!

      @conta.update_columns(last_sync_error: "falha antiga")

      com_ingestor { |_| sincronizar(forcar: true) }

      assert_nil @conta.reload.last_sync_error
    end

    # ------------------------------------------------------------- o escopo

    test "não toca em conta de outra empresa" do
      conectar!

      estranha = criar_conta(tenant: criar_tenant, plataforma: "shopee")

      conectar!(estranha)

      _, chamadas = com_ingestor { |c| [ sincronizar, c ] }

      assert_equal [ @conta.id ], chamadas
    end

    test "conta inativa fica de fora" do
      conectar!

      @conta.update!(status: :inactive)

      _, chamadas = com_ingestor { |c| [ sincronizar, c ] }

      assert_empty chamadas
    end
  end
end
