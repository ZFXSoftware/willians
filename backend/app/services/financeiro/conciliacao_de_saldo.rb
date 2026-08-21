module Financeiro
  # Briefing 2.4 — Controle de Conta Virtual.
  #
  # Compara o saldo que a PLATAFORMA declara com o que o NOSSO razão diz, e
  # aponta a diferença sozinho. É a conferência que fecha a malha: a baixa
  # individual pode estar certa em cada título e ainda assim faltar dinheiro na
  # conta, se algum evento não chegou.
  class ConciliacaoDeSaldo
    # Centavos de arredondamento não são divergência.
    TOLERANCIA = BigDecimal("0.05")

    TIPO_DIVERGENCIA = "saldo_da_conta_virtual".freeze

    def initialize(tenant:, platform_account: nil, start_date: nil, end_date: nil, tolerancia: TOLERANCIA)
      @tenant = tenant

      @platform_account = platform_account

      @end_date = (end_date || Date.current).to_date

      @start_date = (start_date || @end_date - 30).to_date

      @tolerancia = tolerancia
    end

    def call
      resumo = Hash.new(0)

      detalhes = contas.map do |conta|
        resultado = conferir(conta)

        resumo[resultado[:situacao]] += 1

        resultado
      end

      { resumo: resumo.to_h, detalhes: detalhes }
    end

    private

    attr_reader :tenant,
                :platform_account,
                :start_date,
                :end_date,
                :tolerancia

    def contas
      return [platform_account] if platform_account

      tenant.platform_accounts.where(status: :active).order(:id)
    end

    def conferir(conta)
      nosso = BalanceEngine.new(tenant: tenant, platform_account: conta).call

      plataforma = saldo_da_plataforma(conta)

      # Sem o lado da plataforma não há conferência. Registrar o nosso lado
      # como se estivesse conferido seria pior do que não registrar.
      return sem_espelho(conta, nosso) if plataforma.blank?

      base = base_de_comparacao(plataforma)

      # Nem toda plataforma tem "saldo disponível". A Amazon, por exemplo, não
      # tem carteira: o que ela informa é o quanto vai pagar no ciclo em curso.
      # Comparar isso contra o nosso disponível inventaria divergência todo dia.
      return sem_espelho(conta, nosso, motivo: :sem_valor_comparavel) if base.blank?

      da_plataforma = plataforma[base].to_d

      nosso_lado = base == :available ? nosso[:available_balance] : nosso[:future_balance]

      diferenca = (da_plataforma - nosso_lado.to_d).round(2)

      snapshot = gravar!(conta, nosso, plataforma, diferenca, base)

      divergente = diferenca.abs > tolerancia

      if divergente
        abrir_divergencia!(conta, snapshot, plataforma,
                           esperado: da_plataforma, recebido: nosso_lado,
                           diferenca: diferenca, base: base)
      else
        fechar_divergencia!(conta)
      end

      {
        platform_account_id: conta.id,
        platform: conta.platform,
        situacao: divergente ? :divergente : :confere,
        base_da_comparacao: base,
        saldo_plataforma: da_plataforma,
        saldo_interno: nosso_lado,
        diferenca: diferenca,
        origem: plataforma[:source],
        snapshot_id: snapshot.id
      }
    end

    # Compara pelo que a plataforma REALMENTE informa. Preferir o disponível
    # quando existe, e cair no futuro quando é o único número que ela dá.
    def base_de_comparacao(plataforma)
      return :available if plataforma[:available].present?

      return :future if plataforma[:future].present?

      nil
    end

    def saldo_da_plataforma(conta)
      provider_para(conta)&.account_balance(start_date: start_date, end_date: end_date)
    rescue NotImplementedError
      nil
    rescue StandardError => e
      Rails.logger.warn "[ConciliacaoDeSaldo] conta ##{conta.id}: #{e.class} #{e.message}"

      nil
    end

    # O registro guarda o NOME da classe (carregamento tardio), não a classe.
    def provider_para(conta)
      nome = Marketplace::Ingestors::MarketplaceIngestor::PROVIDERS[conta.platform.to_s]

      return if nome.blank?

      classe = nome.constantize

      return unless classe.configured?(conta)

      classe.new(account: conta)
    end

    def sem_espelho(conta, nosso, motivo: :nao_informou)
      mensagem =
        if motivo == :sem_valor_comparavel
          "#{conta.platform} respondeu, mas sem um valor comparável ao nosso saldo."
        else
          "#{conta.platform} não informou saldo: integração não conectada, " \
            "sem suporte a leitura de saldo, ou relatório ainda sendo gerado."
        end

      {
        platform_account_id: conta.id,
        platform: conta.platform,
        situacao: :sem_espelho,
        motivo: motivo,
        saldo_interno: nosso[:available_balance],
        mensagem: mensagem
      }
    end

    def gravar!(conta, nosso, plataforma, diferenca, base = :available)
      snapshot = PlatformBalanceSnapshot.find_or_initialize_by(
        platform_account_id: conta.id, snapshot_date: Date.current
      )

      snapshot.update!(
        tenant: tenant,
        available_balance: nosso[:available_balance],
        future_balance: nosso[:future_balance],
        blocked_balance: nosso[:blocked_balance],
        platform_available_balance: plataforma[:available],
        platform_future_balance: plataforma[:future],
        platform_total_balance: plataforma[:total],
        difference_amount: diferenca,
        platform_source: plataforma[:source],
        metadata: { "conferido_em" => Time.current, "periodo" => "#{start_date}..#{end_date}",
                    "base_da_comparacao" => base }
      )

      snapshot
    end

    # Sem lançamento associado: a diferença é da conta, não de um título. A
    # chave mantém uma divergência aberta por conta, atualizada a cada dia.
    def abrir_divergencia!(conta, snapshot, plataforma, esperado:, recebido:, diferenca:, base:)
      # Busca pela chave DENTRO do metadata, e não pelo metadata inteiro: o
      # registro gravado tem mais campos, e a comparação de hash nunca casaria
      # — criaria uma segunda divergência a cada execução.
      divergencia = divergencia_aberta(conta) ||
                    DivergenceReport.new(tenant_id: tenant.id,
                                         divergence_type: TIPO_DIVERGENCIA,
                                         financial_entry_id: nil)

      divergencia.assign_attributes(
        status: :open,
        # O par comparado, e não sempre o disponível: quando a plataforma só
        # informa o futuro, é o futuro que está em divergência.
        expected_amount: esperado,
        received_amount: recebido,
        difference_amount: diferenca,
        metadata: {
          "chave" => chave(conta),
          "origem" => "conciliacao_de_saldo",
          "platform_account_id" => conta.id,
          "platform" => conta.platform,
          "snapshot_id" => snapshot.id,
          "periodo" => "#{start_date}..#{end_date}",
          "fonte_do_saldo" => plataforma[:source],
          "base_da_comparacao" => base
        }
      )

      divergencia.save!

      divergencia
    end

    def divergencia_aberta(conta)
      DivergenceReport
        .where(tenant_id: tenant.id, divergence_type: TIPO_DIVERGENCIA, financial_entry_id: nil)
        .where("metadata->>'chave' = ?", chave(conta))
        .first
    end

    # Voltou a bater: a divergência aberta se resolve sozinha.
    def fechar_divergencia!(conta)
      DivergenceReport
        .where(tenant_id: tenant.id, divergence_type: TIPO_DIVERGENCIA, status: :open)
        .where("metadata->>'chave' = ?", chave(conta))
        .find_each do |divergencia|
          divergencia.update!(
            status: :resolved,
            resolved_at: Time.current,
            resolution_notes: "Saldo voltou a conferir na leitura de #{Date.current}."
          )
        end
    end

    def chave(conta) = "saldo-conta-#{conta.id}"
  end
end
