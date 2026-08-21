module Financeiro
  # Briefing 2.7, segunda metade: pagamento de nota fiscal feito DIRETO na
  # plataforma precisa ser lançado e baixado no OMIE.
  #
  # É o espelho da BaixaDeRecebimentos do lado do contas a pagar. A corrente é
  # a mesma, invertida:
  #
  #   lançamento de pagamento -> número da NF -> título a pagar no OMIE
  #
  # A mesma regra vale: divergência NÃO é baixada. Baixar por valor que não
  # confere corrompe a contabilidade, e desfazer baixa no OMIE dá trabalho.
  class BaixaDePagamentos
    TOLERANCIA = Conciliacao::ResultadoConciliacao::TOLERANCIA

    CALL = "LancarPagamento".freeze

    ENDPOINT = "financas/contapagar/".freeze

    class ConfiguracaoAusente < StandardError; end

    def initialize(tenant:, client: nil, titulos: nil, start_date: nil, end_date: nil,
                   dry_run: nil, limite: nil)
      @tenant = tenant

      @client, @dry_run, @motivo_da_simulacao =
        EscritaNoOmie.preparar(tenant: tenant, client: client, dry_run: dry_run)

      @titulos = titulos

      @end_date = (end_date || Date.current).to_date

      @start_date = (start_date || @end_date - 90).to_date


      @limite = limite

      @resumo = Hash.new(0)

      @detalhes = []
    end

    def call
      Current.with_tenant(tenant) do
        resumo[:simulacao] = dry_run

        EscritaNoOmie.anotar!(resumo, @motivo_da_simulacao)

        pagamentos.each do |pagamento|
          break if limite && resumo[:baixados] >= limite

          processar(pagamento)
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

    # Pagamentos feitos na plataforma que ainda não foram levados ao OMIE.
    def pagamentos
      FinancialEntry
        .where(tenant_id: tenant.id, entry_type: :payment, direction: :debit)
        .where(occurred_at: start_date.beginning_of_day..end_date.end_of_day)
        .where.missing(:omie_financial_mapping)
        .includes(:invoice, :platform_account)
    end

    def titulos
      @titulos ||= Omie::Readers::OpenPayables
                     .new(client: client)
                     .por_nota_fiscal(start_date: start_date - 365, end_date: end_date)
    end

    def processar(pagamento)
      numero = numero_da_nota(pagamento)

      return registrar(pagamento, :sem_nota, "pagamento sem número de nota fiscal") if numero.blank?

      candidatos = titulos[numero]

      return registrar(pagamento, :titulo_nao_encontrado, "NF #{numero} sem título a pagar em aberto") if candidatos.blank?

      titulo = candidatos.first

      diferenca = (titulo.valor - pagamento.amount).abs

      if diferenca > TOLERANCIA
        abrir_divergencia!(pagamento, titulo, diferenca)

        return registrar(pagamento, :divergente,
                         "NF #{numero}: título #{titulo.valor} x pago #{pagamento.amount}", titulo: titulo)
      end

      return registrar(pagamento, :baixaria, "título #{titulo.codigo_lancamento_omie} (NF #{numero})",
                       titulo: titulo) if dry_run

      baixar!(pagamento, titulo, numero)
    end

    def baixar!(pagamento, titulo, numero)
      resposta = client.request(
        ENDPOINT,
        CALL,
        codigo_lancamento: titulo.codigo_lancamento_omie.to_i,
        codigo_conta_corrente: conta_corrente_id(pagamento),
        valor: titulo.valor.to_f,
        data: pagamento.occurred_at.to_date.strftime("%d/%m/%Y"),
        observacao: "Pagamento realizado na plataforma #{pagamento.platform_account&.platform} — NF #{numero}"
      )

      registrar_mapeamento!(pagamento, titulo, resposta)

      registrar(pagamento, :baixados, "título #{titulo.codigo_lancamento_omie} baixado", titulo: titulo)
    rescue Omie::Client::Error => e
      registrar(pagamento, :falhas, "título #{titulo.codigo_lancamento_omie}: #{e.message}", titulo: titulo)
    end

    # O número pode vir da NF vinculada ou do documento informado no lançamento.
    def numero_da_nota(pagamento)
      bruto = pagamento.invoice&.number.presence ||
              pagamento.metadata&.dig("numero_documento").presence

      Omie::Readers::OpenTitles.normalizar_numero(bruto)
    end

    def conta_corrente_id(pagamento)
      Omie::Settings
        .new(tenant: tenant, platform_account: pagamento.platform_account)
        .conta_corrente_id
    rescue Omie::Settings::MissingConfig => e
      raise ConfiguracaoAusente, e.message
    end

    def registrar_mapeamento!(pagamento, titulo, resposta)
      mapeamento = OmieFinancialMapping.find_or_initialize_by(financial_entry_id: pagamento.id)

      mapeamento.update!(
        tenant_id: tenant.id,
        omie_financial_id: titulo.codigo_lancamento_omie.to_s,
        synced: true,
        synced_at: Time.current,
        metadata: (mapeamento.metadata || {}).merge(
          "baixa_pagamento" => {
            "codigo_baixa" => resposta["codigo_baixa"],
            "valor" => titulo.valor.to_s,
            "em" => Time.current
          }
        )
      )
    end

    def abrir_divergencia!(pagamento, titulo, diferenca)
      DivergenceReport.find_or_create_by!(
        tenant_id: tenant.id,
        financial_entry_id: pagamento.id,
        divergence_type: "valor_divergente_no_pagamento",
        status: "open"
      ) do |d|
        d.expected_amount = titulo.valor
        d.received_amount = pagamento.amount
        d.difference_amount = diferenca
        d.metadata = {
          "origem" => "baixa_de_pagamentos",
          "nota_fiscal" => titulo.numero_nf,
          "codigo_lancamento_omie" => titulo.codigo_lancamento_omie
        }
      end
    end

    def registrar(pagamento, chave, mensagem, titulo: nil)
      resumo[chave] += 1

      detalhes << {
        financial_entry_id: pagamento.id,
        resultado: chave,
        mensagem: mensagem,
        codigo_lancamento_omie: titulo&.codigo_lancamento_omie
      }
    end
  end
end
