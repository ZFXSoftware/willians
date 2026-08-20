module Financeiro
  # Briefing 2.7, primeira metade: identificar transferências entre contas
  # feitas nas plataformas e refleti-las no OMIE.
  #
  # O saque do marketplace é literalmente isso: o dinheiro sai da conta virtual
  # da plataforma e entra na conta bancária. No nosso razão ele chega como
  # `settlement` ou `transfer` (o relatório de liberações do ML marca `payout`).
  #
  # O OMIE modela transferência como um lançamento de conta corrente com a
  # conta de DESTINO preenchida — estrutura confirmada lendo lançamentos reais
  # da base do cliente (`transferencia.nCodCCDestino`).
  class TransferenciaEntreContas
    ENDPOINT = "financas/contacorrentelancamentos/".freeze

    CALL = "IncluirLancCC".freeze

    # Mesmo prefixo dos títulos que criamos: o `cCodIntLanc` é a nossa chave de
    # idempotência do lado do OMIE, e não pode colidir com o do TrackCash.
    PREFIXO = "WLL-TRF-".freeze

    DESTINO_KEY = "omie_conta_corrente_destino_id".freeze

    TIPOS = %w[settlement transfer].freeze

    class ConfiguracaoAusente < StandardError; end

    def initialize(tenant:, client: nil, start_date: nil, end_date: nil, dry_run: nil, limite: nil)
      @tenant = tenant

      @client = client || (Omie::Client.configured?(tenant: tenant) ? Omie::Client.new(tenant: tenant) : Omie::FakeOmieClient.new)

      @end_date = (end_date || Date.current).to_date

      @start_date = (start_date || @end_date - 30).to_date

      @dry_run = dry_run.nil? ? !Omie::Client.writes_enabled? : dry_run

      @limite = limite

      @resumo = Hash.new(0)

      @detalhes = []
    end

    def call
      Current.with_tenant(tenant) do
        resumo[:simulacao] = dry_run

        transferencias.each do |lancamento|
          break if limite && resumo[:lancadas] >= limite

          processar(lancamento)
        end

        { resumo: resumo.to_h, detalhes: detalhes }
      end
    end

    private

    attr_reader :tenant,
                :client,
                :dry_run,
                :limite,
                :start_date,
                :end_date,
                :resumo,
                :detalhes

    # `where.missing` garante a idempotência: o que já foi levado ao OMIE não
    # volta, mesmo reexecutando o mesmo período.
    def transferencias
      FinancialEntry
        .where(tenant_id: tenant.id, entry_type: TIPOS)
        .where(occurred_at: start_date.beginning_of_day..end_date.end_of_day)
        .where.missing(:omie_financial_mapping)
        .includes(:platform_account)
        .order(:occurred_at)
    end

    def processar(lancamento)
      origem = conta_origem(lancamento)

      destino = conta_destino(lancamento)

      if origem == destino
        return registrar(lancamento, :mesma_conta,
                         "origem e destino são a mesma conta (#{origem}); nada a transferir")
      end

      return registrar(lancamento, :lancaria, "#{lancamento.amount} de #{origem} para #{destino}") if dry_run

      lancar!(lancamento, origem, destino)
    end

    def lancar!(lancamento, origem, destino)
      resposta = client.request(ENDPOINT, CALL, payload(lancamento, origem, destino))

      registrar_mapeamento!(lancamento, resposta)

      registrar(lancamento, :lancadas, "transferência de #{origem} para #{destino} lançada")
    rescue Omie::Client::Error => e
      registrar(lancamento, :falhas, e.message)
    end

    def payload(lancamento, origem, destino)
      {
        cCodIntLanc: "#{PREFIXO}#{lancamento.id}",
        cabecalho: {
          dDtLanc: lancamento.occurred_at.to_date.strftime("%d/%m/%Y"),
          nCodCC: origem,
          nValorLanc: lancamento.amount.to_f
        },
        detalhes: {
          cObs: observacao(lancamento)
        },
        # É este campo que transforma o lançamento em transferência.
        transferencia: {
          nCodCCDestino: destino
        }
      }
    end

    def observacao(lancamento)
      plataforma = lancamento.platform_account&.platform

      "Transferência do saldo #{plataforma} — #{lancamento.external_id}"
    end

    def conta_origem(lancamento)
      Omie::Settings
        .new(tenant: tenant, platform_account: lancamento.platform_account)
        .conta_corrente_id
    rescue Omie::Settings::MissingConfig => e
      raise ConfiguracaoAusente, e.message
    end

    # A conta de destino é a bancária, para onde o marketplace deposita. Não
    # tem padrão: chutar uma jogaria dinheiro na conta errada do cliente.
    def conta_destino(lancamento)
      valor = lancamento.platform_account&.metadata&.[](DESTINO_KEY).presence ||
              tenant.metadata&.[](DESTINO_KEY).presence ||
              ENV[DESTINO_KEY.upcase].presence

      if valor.blank?
        raise ConfiguracaoAusente,
              "#{DESTINO_KEY} não configurado. É a conta corrente do OMIE para onde o " \
              "marketplace deposita o saque. Obtenha o código em ListarContasCorrentes e " \
              "grave em platform_account.metadata ou tenant.metadata."
      end

      valor.to_i
    end

    def registrar_mapeamento!(lancamento, resposta)
      mapeamento = OmieFinancialMapping.find_or_initialize_by(financial_entry_id: lancamento.id)

      mapeamento.update!(
        tenant_id: tenant.id,
        omie_financial_id: (resposta["nCodLanc"] || resposta["codigo_lancamento_omie"]).to_s,
        synced: true,
        synced_at: Time.current,
        metadata: (mapeamento.metadata || {}).merge(
          "transferencia" => {
            "codigo_integracao" => "#{PREFIXO}#{lancamento.id}",
            "valor" => lancamento.amount.to_s,
            "em" => Time.current
          }
        )
      )
    end

    def registrar(lancamento, chave, mensagem)
      resumo[chave] += 1

      detalhes << {
        financial_entry_id: lancamento.id,
        external_id: lancamento.external_id,
        resultado: chave,
        mensagem: mensagem
      }
    end
  end
end
