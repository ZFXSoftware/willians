module Financeiro
  # Briefing 2.6 — valores cobrados ou recebidos SEM vínculo com pedido ou nota
  # fiscal vão para o OMIE numa categoria transitória, para não sumirem do
  # extrato.
  #
  # É o caso das taxas de período (o faturamento do Mercado Livre vem agregado
  # por mês, sem pedido), dos ajustes da plataforma e de qualquer entrada que
  # chegue solta. Sem isto, o dinheiro aparece no razão daqui e nunca no ERP.
  #
  # Recebido (crédito) vira conta a RECEBER; cobrado (débito) vira conta a
  # PAGAR — é aqui que a conta a pagar volta ao sistema.
  class ValoresNaoVinculados
    RECEBER = { endpoint: "financas/contareceber/", call: "IncluirContaReceber" }.freeze

    PAGAR = { endpoint: "financas/contapagar/", call: "IncluirContaPagar" }.freeze

    # Lançamentos que existem só para fechar o saldo daqui e não representam
    # cobrança nem recebimento novo no ERP.
    TIPOS_IGNORADOS = %w[settlement transfer].freeze

    INTEGRATION_PREFIX = Omie::Mappers::FinancialEntryMapper::INTEGRATION_PREFIX

    class ConfiguracaoAusente < StandardError; end

    def initialize(tenant:, start_date:, end_date:, client: nil, dry_run: nil)
      @tenant = tenant

      @start_date = start_date.to_date

      @end_date = end_date.to_date

      @client, @dry_run, @motivo_da_simulacao =
        EscritaNoOmie.preparar(tenant: tenant, client: client, dry_run: dry_run)


      @resumo = Hash.new(0)

      @detalhes = []
    end

    def call
      resumo[:simulacao] = dry_run

      EscritaNoOmie.anotar!(resumo, @motivo_da_simulacao)

      lancamentos.find_each { |entrada| processar(entrada) }

      { resumo: resumo.to_h, detalhes: detalhes }
    end

    private

    attr_reader :tenant, :start_date, :end_date, :client, :dry_run, :resumo, :detalhes

    # Sem pedido E sem nota: é o que o briefing chama de não vinculado. Já
    # enviados ficam de fora pelo mapeamento.
    def lancamentos
      FinancialEntry
        .where(tenant_id: tenant.id, order_id: nil, invoice_id: nil)
        .where(occurred_at: start_date.beginning_of_day..end_date.end_of_day)
        .where.not(entry_type: TIPOS_IGNORADOS)
        .where.missing(:omie_financial_mapping)
        .includes(:platform_account)
    end

    def processar(entrada)
      resumo[:encontrados] += 1

      destino = entrada.credit? ? RECEBER : PAGAR

      payload = montar(entrada)

      if dry_run
        return registrar(entrada, :lancaria,
                         "#{destino[:call]} categoria #{payload[:codigo_categoria]} valor #{payload[:valor_documento]}")
      end

      resposta = client.request(destino[:endpoint], destino[:call], payload)

      registrar_mapeamento!(entrada, payload, resposta)

      registrar(entrada, :lancados, "#{destino[:call]} -> #{resposta['codigo_lancamento_omie']}")
    rescue Omie::Settings::MissingConfig => e
      raise ConfiguracaoAusente, e.message
    rescue Omie::Client::Error => e
      registrar(entrada, :falhas, e.message)
    end

    def montar(entrada)
      settings = Omie::Settings.for(entrada)

      data = (entrada.available_on || entrada.occurred_at.to_date).strftime("%d/%m/%Y")

      {
        codigo_lancamento_integracao: "#{INTEGRATION_PREFIX}-NV-#{entrada.id}",

        codigo_cliente_fornecedor: settings.cliente_fornecedor_id,

        id_conta_corrente: settings.conta_corrente_id,

        data_vencimento: data,

        data_previsao: data,

        valor_documento: entrada.amount.to_f,

        codigo_categoria: settings.categoria_transitoria(entrada.direction),

        observacao: descricao(entrada)
      }
    end

    def descricao(entrada)
      [
        "Valor sem vínculo",
        entrada.platform_account&.platform,
        entrada.entry_type,
        entrada.external_id
      ].compact.join(" · ")
    end

    def registrar_mapeamento!(entrada, payload, resposta)
      OmieFinancialMapping.create!(
        tenant_id: tenant.id,
        financial_entry_id: entrada.id,
        omie_financial_id: resposta["codigo_lancamento_omie"].to_s.presence,
        omie_category_id: payload[:codigo_categoria],
        synced: true,
        synced_at: Time.current,
        metadata: {
          "origem" => "valores_nao_vinculados",
          "direcao" => entrada.direction,
          "payload_enviado" => payload,
          "resposta" => resposta
        }
      )
    end

    def registrar(entrada, chave, mensagem)
      resumo[chave] += 1

      detalhes << {
        financial_entry_id: entrada.id,
        external_id: entrada.external_id,
        direcao: entrada.direction,
        valor: entrada.amount,
        resultado: chave,
        mensagem: mensagem
      }
    end
  end
end
