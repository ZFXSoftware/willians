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

    # Quantas notas cabem numa execução.
    #
    # Cada nota são DUAS chamadas ao OMIE com pausa entre elas — o OMIE bloqueia
    # repetição em sequência. Dá uns dois segundos por nota, e 3672 notas viram
    # duas horas: muito além de qualquer requisição de navegador, que cai no
    # meio e deixa o envio pela metade sem ninguém saber quanto foi.
    #
    # Com o lote, cada execução termina rápido e o progresso é visível. O que
    # sobra vai na próxima — pela tela ou pelo ciclo automático.
    LOTE_PADRAO = 100

    # Falhas seguidas param o ciclo automático.
    #
    # Se o OMIE está recusando, insistir de hora em hora não conserta nada e
    # ainda enche a contabilidade de tentativa. Melhor parar e avisar do que
    # martelar em silêncio.
    LIMITE_DE_FALHAS = 3

    class ConfiguracaoAusente < StandardError; end

    class SemMarcoInicial < StandardError; end

    class MuitasFalhas < StandardError; end

    def initialize(tenant:, platform_account: nil, client: nil, dry_run: nil,
                   limite: nil, pausa: PAUSA_PADRAO, automatico: false)
      @tenant = tenant

      @platform_account = platform_account

      @limite = limite

      @pausa = pausa

      @automatico = automatico

      @client, @dry_run, @motivo_da_simulacao =
        EscritaNoOmie.preparar(tenant: tenant, client: client, dry_run: dry_run)
    end

    def call
      resumo = Hash.new(0)

      resumo[:amostra] = []

      Current.with_tenant(tenant) do
        exigir_configuracao!

        exigir_marco_inicial! if automatico

        recusar_se_travado! if automatico

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

      registrar_saude!(resumo) unless dry_run

      # Quantas ainda faltam DEPOIS desta execução. É o que permite a tela
      # continuar de onde parou e mostrar progresso, em vez de sumir por duas
      # horas e voltar sem dizer o que fez.
      resumo[:pendentes] = [ @pendentes_total.to_i - resumo[:enviadas].to_i, 0 ].max

      resumo
    end

    private

    attr_reader :tenant, :platform_account, :client, :dry_run, :limite, :pausa, :automatico

    # Marco inicial: onde começa a nossa responsabilidade.
    #
    # Sem isto, o primeiro ciclo de um cliente novo tentaria mandar o histórico
    # inteiro dele para o OMIE — inclusive o que o sistema antigo já lançou.
    def marco
      @marco ||= Integracoes::Config.get("omie", :envio_a_partir_de, tenant: tenant).presence&.to_date
    rescue Date::Error
      nil
    end

    def exigir_marco_inicial!
      return if marco

      raise SemMarcoInicial,
            "Defina 'Enviar notas emitidas a partir de' em Configurações > OMIE. " \
            "Sem essa data, o envio automático tentaria mandar todo o histórico da empresa."
    end

    # Contagem de falhas SEGUIDAS, e não total: uma nota problemática no meio
    # de mil não pode parar o ciclo, mas três execuções seguidas falhando
    # significa que alguma coisa mudou e insistir não resolve.
    def saude
      tenant.metadata["omie_envio_saude"] || {}
    end

    def recusar_se_travado!
      return if saude["falhas_seguidas"].to_i < LIMITE_DE_FALHAS

      raise MuitasFalhas,
            "O envio automático está parado depois de #{saude['falhas_seguidas']} execuções " \
            "seguidas com falha (última: #{saude['ultimo_erro']}). Resolva e envie uma nota " \
            "pela tela para destravar."
    end

    def registrar_saude!(resumo)
      falhou = resumo[:falhas].to_i.positive?

      seguidas = falhou ? saude["falhas_seguidas"].to_i + 1 : 0

      tenant.update_columns(
        metadata: tenant.metadata.merge(
          "omie_envio_saude" => {
            "em" => Time.current,
            "enviadas" => resumo[:enviadas],
            "falhas_seguidas" => seguidas,
            "ultimo_erro" => falhou ? Array(resumo[:erros]).first : nil
          }.compact
        ),
        updated_at: Time.current
      )
    end

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

      escopo = escopo.where(issued_at: marco..) if marco

      @pendentes_total = escopo.count

      if platform_account
        escopo = escopo.joins(:order).where(orders: { platform_account_id: platform_account.id })
      end

      # Sempre limitado: sem teto, uma execução com milhares de notas não
      # termina dentro de nenhuma requisição, e cai no meio.
      escopo.limit(limite || LOTE_PADRAO)
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
