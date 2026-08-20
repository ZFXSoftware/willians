require "test_helper"

module Financeiro
  # Briefing 2.7. O saque do marketplace é uma transferência: sai da conta
  # virtual da plataforma e entra na conta bancária. Errar a conta de destino
  # joga dinheiro no lugar errado da contabilidade do cliente.
  class TransferenciaEntreContasTest < ActiveSupport::TestCase
    setup do
      @tenant = criar_tenant
      @conta = criar_conta(tenant: @tenant, metadata: {
        "omie_conta_corrente_id" => "6455415244",
        "omie_conta_corrente_destino_id" => "12557610062"
      })
    end

    def saque(valor: 1000, tipo: :settlement, external_id: nil)
      criar_lancamento(tenant: @tenant, conta: @conta, tipo: tipo, direcao: :debit,
                       valor: valor, external_id: external_id || "MLREL-PAY-#{SecureRandom.hex(3)}-PAYOUT",
                       ocorrido_em: 2.days.ago)
    end

    def rodar(client:, **opcoes)
      TransferenciaEntreContas.new(tenant: @tenant, client: client, **opcoes).call
    end

    test "simula quando a escrita no OMIE está bloqueada" do
      saque
      espiao = OmieEspiao.new

      resultado = com_env("OMIE_ALLOW_WRITES" => nil) { rodar(client: espiao) }

      assert resultado[:resumo][:simulacao]
      assert_empty espiao.chamadas, "simulação não pode tocar no OMIE"
      assert_equal 1, resultado[:resumo][:lancaria]
    end

    test "lança a transferência com a conta de destino preenchida" do
      lancamento = saque(valor: 1500)
      espiao = OmieEspiao.new

      rodar(client: espiao, dry_run: false)

      chamada = espiao.chamadas.first

      assert_equal "financas/contacorrentelancamentos/", chamada[:endpoint]
      assert_equal "IncluirLancCC", chamada[:call]

      params = chamada[:params]

      assert_equal 6_455_415_244, params[:cabecalho][:nCodCC], "sai da conta da plataforma"
      # É este campo que transforma o lançamento em transferência.
      assert_equal 12_557_610_062, params[:transferencia][:nCodCCDestino]
      assert_equal 1500.0, params[:cabecalho][:nValorLanc]
      assert_match %r{\A\d{2}/\d{2}/\d{4}\z}, params[:cabecalho][:dDtLanc]
      assert_equal "WLL-TRF-#{lancamento.id}", params[:cCodIntLanc]
    end

    test "identificador não colide com o do TrackCash" do
      saque
      espiao = OmieEspiao.new

      rodar(client: espiao, dry_run: false)

      assert espiao.chamadas.first[:params][:cCodIntLanc].start_with?("WLL-")
    end

    test "não relança o que já foi ao OMIE" do
      saque

      rodar(client: OmieEspiao.new, dry_run: false)

      segunda = OmieEspiao.new
      resumo = rodar(client: segunda, dry_run: false)[:resumo]

      assert_equal 0, resumo[:lancadas].to_i
      assert_empty segunda.chamadas, "reexecutar duplicaria a transferência"
    end

    test "grava o rastro para auditoria" do
      lancamento = saque

      rodar(client: OmieEspiao.new, dry_run: false)

      mapeamento = OmieFinancialMapping.find_by(financial_entry_id: lancamento.id)

      assert mapeamento&.synced?
      assert_equal "WLL-TRF-#{lancamento.id}", mapeamento.metadata.dig("transferencia", "codigo_integracao")
    end

    test "sem conta de destino configurada, falha com o caminho para resolver" do
      saque
      @conta.update!(metadata: @conta.metadata.except("omie_conta_corrente_destino_id"))

      erro = assert_raises(TransferenciaEntreContas::ConfiguracaoAusente) do
        com_env("OMIE_CONTA_CORRENTE_DESTINO_ID" => nil) { rodar(client: OmieEspiao.new, dry_run: false) }
      end

      assert_match(/destino/, erro.message)
      assert_includes erro.message, "ListarContasCorrentes"
    end

    test "origem igual ao destino não vira transferência" do
      saque
      @conta.update!(metadata: @conta.metadata.merge("omie_conta_corrente_destino_id" => "6455415244"))

      espiao = OmieEspiao.new
      resumo = rodar(client: espiao, dry_run: false)[:resumo]

      assert_equal 1, resumo[:mesma_conta]
      assert_empty espiao.chamadas, "transferir para a própria conta não faz sentido"
    end

    test "venda e taxa não viram transferência" do
      criar_lancamento(tenant: @tenant, conta: @conta, tipo: :sale, direcao: :credit,
                       valor: 100, ocorrido_em: 2.days.ago)
      criar_lancamento(tenant: @tenant, conta: @conta, tipo: :fee, direcao: :debit,
                       valor: 10, ocorrido_em: 2.days.ago)

      espiao = OmieEspiao.new
      rodar(client: espiao, dry_run: false)

      assert_empty espiao.chamadas
    end

    test "limite interrompe o lote para validar em uma antes de soltar" do
      3.times { saque }

      espiao = OmieEspiao.new
      rodar(client: espiao, dry_run: false, limite: 1)

      assert_equal 1, espiao.chamadas.size
    end
  end
end
