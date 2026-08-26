module Financeiro
  # Leva as notas fiscais do Tiny para o OMIE como títulos a receber.
  #
  # O OMIE do cliente é novo e está vazio; o faturamento dele vive no Tiny. Sem
  # os títulos lá, a conciliação compara o repasse do marketplace com o nada, e
  # a tela mostra "sem título correspondente" para tudo — que é exatamente o
  # que estava acontecendo.
  #
  # Cada nota vira DUAS chamadas: o cadastro do comprador (o título é lançado
  # contra ele, não contra o marketplace) e o título em si. As duas são
  # idempotentes pela chave de integração, então reprocessar atualiza em vez de
  # duplicar — importante quando são milhares.
  #
  # Simula por padrão: sem OMIE_ALLOW_WRITES nada é gravado, e o resumo mostra
  # o que seria enviado.
  class EnvioDeNotasAoOmie
    CLIENTE = { endpoint: "geral/clientes/", call: "UpsertCliente" }.freeze

    TITULO = { endpoint: "financas/contareceber/", call: "IncluirContaReceber" }.freeze

    # O OMIE serializa chamadas por método e bloqueia repetição em sequência.
    # Sem pausa, um lote de milhares vira bloqueio no meio do caminho.
    PAUSA_PADRAO = 1.0

    class ConfiguracaoAusente < StandardError; end

    def initialize(tenant:, platform_account: nil, client: nil, dry_run: nil,
                   limite: nil, pausa: PAUSA_PADRAO)
      @tenant = tenant

      @platform_account = platform_account

      @limite = limite

      @pausa = pausa

      @client, @dry_run, @motivo_da_simulacao =
        EscritaNoOmie.preparar(tenant: tenant, client: client, dry_run: dry_run)
    end

    def call
      resumo = Hash.new(0)

      resumo[:amostra] = []

      Current.with_tenant(tenant) do
        exigir_configuracao!

        notas.each do |nota|
          processar(nota, resumo)
        rescue Omie::Mappers::InvoiceMapper::SemComprador => e
          resumo[:sem_comprador] += 1

          Rails.logger.warn "[EnvioDeNotas] #{e.message}"
        rescue StandardError => e
          resumo[:falhas] += 1

          Rails.logger.error "[EnvioDeNotas] nota ##{nota.id}: #{e.class} #{e.message}"

          resumo[:erros] ||= []
          resumo[:erros] << "NF #{nota.number}: #{e.message}" if resumo[:erros].size < 5
        end
      end

      EscritaNoOmie.anotar!(resumo, @motivo_da_simulacao)

      resumo
    end

    private

    attr_reader :tenant, :platform_account, :client, :dry_run, :limite, :pausa

    def processar(nota, resumo)
      mapper = Omie::Mappers::InvoiceMapper.new(invoice: nota, settings: settings_de(nota))

      cliente = mapper.cliente

      titulo = mapper.titulo

      resumo[:previstas] += 1

      resumo[:amostra] << { nf: nota.number, comprador: cliente[:razao_social],
                            valor: titulo[:valor_documento] } if resumo[:amostra].size < 5

      return if dry_run

      client.request(CLIENTE[:endpoint], CLIENTE[:call], cliente)

      dormir

      resposta = client.request(TITULO[:endpoint], TITULO[:call], titulo)

      registrar!(nota, resposta)

      resumo[:enviadas] += 1

      dormir
    end

    # O código do título no OMIE fica na nota: é o que faz reprocessar não
    # tentar de novo, e o que permite achar o título depois.
    def registrar!(nota, resposta)
      codigo = resposta["codigo_lancamento_omie"] || resposta["codigo_lancamento_integracao"]

      nota.update!(
        metadata: nota.metadata.merge(
          "omie_codigo_lancamento" => codigo,
          "omie_enviado_em" => Time.current
        )
      )
    end

    # Notas que ainda não foram para o OMIE. A checagem é pelo carimbo na
    # própria nota, e não por uma consulta ao OMIE: são milhares, e perguntar
    # uma a uma seria mais lento do que enviar.
    def notas
      escopo = Invoice
                 .where(tenant_id: tenant.id, operation_type: :sale)
                 .where.not(status: :cancelled)
                 .where("invoices.metadata->>'omie_codigo_lancamento' IS NULL")
                 .includes(:order)
                 .order(:issued_at, :id)

      if platform_account
        escopo = escopo.joins(:order).where(orders: { platform_account_id: platform_account.id })
      end

      escopo = escopo.limit(limite) if limite

      escopo
    end

    def settings_de(nota)
      Omie::Settings.new(tenant: tenant, platform_account: nota.order&.platform_account)
    end

    # A conta corrente e a categoria são da empresa e valem para todo o lote —
    # descobrir que faltam na milésima nota seria descobrir tarde.
    def exigir_configuracao!
      settings = Omie::Settings.new(tenant: tenant, platform_account: platform_account)

      settings.conta_corrente_id
    rescue Omie::Settings::MissingConfig => e
      raise ConfiguracaoAusente, e.message
    end

    def dormir
      sleep(pausa) if pausa.to_f.positive?
    end
  end
end
