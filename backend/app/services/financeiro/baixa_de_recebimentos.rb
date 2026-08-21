module Financeiro
  # Baixa automática dos recebimentos no OMIE, vinculada à nota fiscal.
  #
  # A corrente percorrida é:
  #
  #   repasse -> recebíveis -> pedido -> nota fiscal -> título no OMIE
  #
  # O elo pedido -> nota vem do Tiny (Fiscal::Tiny::InvoiceSync); o elo nota ->
  # título é o número da NF, único identificador presente em toda a base.
  #
  # REGRA: divergência NÃO é baixada. Se o valor do título não confere com o que
  # o marketplace repassou, o caso vira divergência para revisão humana. Baixar
  # por um valor que não bate corromperia a contabilidade do cliente, e desfazer
  # baixa no OMIE é trabalhoso.
  class BaixaDeRecebimentos
    TOLERANCIA = Conciliacao::ResultadoConciliacao::TOLERANCIA

    class ConfiguracaoAusente < StandardError; end

    def initialize(payout_batch:, client: nil, titulos: nil, dry_run: nil)
      @payout = payout_batch

      tenant = payout_batch.tenant

      @client, @dry_run, @motivo_da_simulacao =
        EscritaNoOmie.preparar(tenant: tenant, client: client, dry_run: dry_run)

      @titulos = titulos


      @resumo = Hash.new(0)

      @detalhes = []
    end

    def call
      resumo[:simulacao] = dry_run

      EscritaNoOmie.anotar!(resumo, @motivo_da_simulacao)

      recebiveis.each { |recebivel| processar(recebivel) }

      { resumo: resumo.to_h, detalhes: detalhes }
    end

    private

    attr_reader :payout, :client, :dry_run, :resumo, :detalhes

    def tenant = payout.tenant

    def indice_de_titulos
      @titulos ||= Omie::Readers::OpenTitles
                     .new(client: client)
                     .por_nota_fiscal
    end

    def recebiveis
      ReceivableUnit
        .joins(:financial_entry_allocations)
        .where(financial_entry_allocations: { payout_batch_id: payout.id })
        .includes(:invoice)
        .distinct
    end

    def processar(recebivel)
      resumo[:recebiveis] += 1

      nota = recebivel.invoice

      return registrar(recebivel, :sem_nota, "recebível sem nota fiscal vinculada") if nota.blank?

      numero = Omie::Readers::OpenTitles.normalizar_numero(nota.number)

      candidatos = indice_de_titulos[numero] || []

      return registrar(recebivel, :titulo_nao_encontrado, "NF #{nota.number} sem título em aberto no OMIE") if candidatos.empty?

      total_omie = candidatos.sum(BigDecimal("0")) { |t| t.valor }

      diferenca = recebivel.gross_amount.to_d - total_omie

      if diferenca.abs > TOLERANCIA
        abrir_divergencia!(recebivel, nota, total_omie, diferenca)

        return registrar(recebivel, :divergente,
                         "NF #{nota.number}: repasse #{recebivel.gross_amount} x título #{total_omie}")
      end

      candidatos.each { |titulo| baixar!(recebivel, nota, titulo) }
    end

    def baixar!(recebivel, nota, titulo)
      if dry_run
        return registrar(recebivel, :baixaria, "título #{titulo.codigo_lancamento_omie} (NF #{nota.number})",
                         titulo: titulo)
      end

      resposta = client.request(
        "financas/contareceber/",
        "LancarRecebimento",
        codigo_lancamento: titulo.codigo_lancamento_omie.to_i,
        codigo_conta_corrente: conta_corrente_id,
        valor: titulo.valor.to_f,
        data: (payout.paid_at || Time.current).to_date.strftime("%d/%m/%Y"),
        observacao: "Baixa automática — repasse #{payout.external_id}"
      )

      registrar_mapeamento!(recebivel, titulo, resposta)

      registrar(recebivel, :baixados, "título #{titulo.codigo_lancamento_omie} baixado", titulo: titulo)
    rescue Omie::Client::Error => e
      registrar(recebivel, :falhas, "título #{titulo.codigo_lancamento_omie}: #{e.message}", titulo: titulo)
    end

    def conta_corrente_id
      @conta_corrente_id ||=
        Omie::Settings
          .new(tenant: tenant, platform_account: payout.platform_account)
          .conta_corrente_id
    rescue Omie::Settings::MissingConfig => e
      raise ConfiguracaoAusente, e.message
    end

    # Guarda o vínculo com o título para auditoria e para não baixar duas vezes.
    def registrar_mapeamento!(recebivel, titulo, resposta)
      entrada = entrada_de_venda(recebivel)

      return if entrada.blank?

      mapeamento = OmieFinancialMapping.find_or_initialize_by(financial_entry_id: entrada.id)

      mapeamento.update!(
        tenant_id: tenant.id,
        omie_financial_id: titulo.codigo_lancamento_omie.to_s,
        synced: true,
        synced_at: Time.current,
        metadata: (mapeamento.metadata || {}).merge(
          "baixa" => {
            "payout" => payout.external_id,
            "codigo_baixa" => resposta["codigo_baixa"],
            "valor" => titulo.valor.to_s,
            "em" => Time.current
          }
        )
      )
    end

    def entrada_de_venda(recebivel)
      FinancialEntry
        .sales
        .where(tenant_id: tenant.id, order_id: recebivel.order_id)
        .first
    end

    def abrir_divergencia!(recebivel, nota, total_omie, diferenca)
      entrada = entrada_de_venda(recebivel)

      return if entrada.blank?

      DivergenceReport.find_or_create_by!(
        tenant_id: tenant.id,
        financial_entry_id: entrada.id,
        divergence_type: "valor_divergente_na_baixa",
        status: "open"
      ) do |d|
        d.expected_amount = total_omie
        d.received_amount = recebivel.gross_amount
        d.difference_amount = diferenca
        d.metadata = {
          "origem" => "baixa_de_recebimentos",
          "payout_batch_id" => payout.id,
          "nota_fiscal" => nota.number,
          "receivable_unit_id" => recebivel.id
        }
      end
    end

    def registrar(recebivel, chave, mensagem, titulo: nil)
      resumo[chave] += 1

      detalhes << {
        receivable_unit_id: recebivel.id,
        resultado: chave,
        mensagem: mensagem,
        codigo_lancamento_omie: titulo&.codigo_lancamento_omie
      }
    end
  end
end
