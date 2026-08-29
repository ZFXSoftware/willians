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
    CLIENTE = { endpoint: "geral/clientes/", call: "IncluirCliente" }.freeze

    # Busca por CPF/CNPJ é LISTAGEM COM FILTRO, e não consulta.
    #
    # `ConsultarCliente` só aceita a chave do cadastro — código do OMIE ou
    # código de integração —, e devolve "Tag [CNPJ_CPF] não faz parte da
    # estrutura do tipo complexo [clientes_cadastro_chave]". Que é justamente o
    # que não temos: o cadastro veio do sistema antigo, com integração vazia.
    BUSCA_CLIENTE = { endpoint: "geral/clientes/", call: "ListarClientes" }.freeze

    # Como o OMIE diz "esse CPF não está cadastrado". Não há código próprio na
    # resposta: sobra reconhecer o texto.
    NAO_CADASTRADO = /não (existe|foi encontrado)|nao (existe|encontrado)|not found/i

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
    # O proxy corta em 5 minutos. Cada nota são até três chamadas ao OMIE
    # (consultar o comprador, criá-lo se não existir, criar o título) com pausa
    # entre elas — uns 3 segundos. 40 notas dão ~2 minutos, com folga para
    # quando o OMIE fica lento.
    LOTE_PADRAO = 40

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

      # Criadas na mão, e não com `||=`, porque o padrão do hash é ZERO: para
      # uma chave ausente, `resumo[:erros] ||= []` encontra 0, considera
      # preenchido e não atribui nada. Depois `0.size` devolve 8, a guarda
      # `< 5` reprova, e nenhuma mensagem entra na lista.
      #
      # Resultado: a tela mostrava "1 nota recusada pelo OMIE" e nenhuma
      # palavra sobre o motivo — o defeito mais caro possível numa lista de
      # erros, que é ela estar sempre vazia.
      resumo[:amostra] = []

      resumo[:erros] = []

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

      resumo[:previstas] += 1

      if resumo[:amostra].size < 5
        resumo[:amostra] << { nf: nota.number, comprador: cliente[:razao_social],
                              valor: nota.total_amount.to_f }
      end

      return if dry_run

      codigo = resolver_cliente!(mapper, cliente)

      resposta = client.request(TITULO[:endpoint], TITULO[:call], mapper.titulo(codigo_cliente: codigo))

      registrar!(nota, resposta)

      resumo[:enviadas] += 1

      dormir
    end

    # Consulta pelo CPF/CNPJ e só cria quando não existe.
    #
    # Criar às cegas não funciona: a base do cliente já tem os compradores, com
    # código de integração vazio, e o OMIE recusa a inclusão pelo CPF repetido
    # ("Cliente já cadastrado ... com o Id [X] e código de integração []").
    # Era isso que impedia TODOS os títulos de nascerem.
    #
    # O cache vale por execução: dentro de um lote o mesmo comprador pode
    # aparecer em várias notas, e consultar de novo é chamada jogada fora — e o
    # OMIE bloqueia repetição em sequência.
    def resolver_cliente!(mapper, payload)
      cache[mapper.documento] ||= procurar_cliente(mapper) || incluir_cliente!(payload)
    end

    def cache = @cache ||= {}

    # Tenta sem pontuação e, se não achar, com — o OMIE guarda formatado, e não
    # dá para saber se o filtro normaliza. A segunda tentativa só acontece no
    # caminho em que criaríamos o cadastro de qualquer forma.
    def procurar_cliente(mapper)
      [ mapper.documento, mapper.documento_original ].compact_blank.uniq.each do |busca|
        codigo = buscar_por_documento(busca)

        return codigo if codigo
      end

      nil
    end

    def buscar_por_documento(documento)
      resposta = client.request(
        BUSCA_CLIENTE[:endpoint], BUSCA_CLIENTE[:call],
        pagina: 1, registros_por_pagina: 1, clientesFiltro: { cnpj_cpf: documento }
      )

      dormir

      resposta.dig("clientes_cadastro", 0, "codigo_cliente_omie")
    rescue Omie::Client::ApiError => e
      # "Não existem registros" é resposta, não falha.
      raise unless e.message.match?(NAO_CADASTRADO)

      dormir

      nil
    end

    def incluir_cliente!(payload)
      resposta = client.request(CLIENTE[:endpoint], CLIENTE[:call], payload)

      dormir

      resposta["codigo_cliente_omie"]
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
                 .where(tenant_id: tenant.id)
                 .nao_enviadas_ao_omie(marco)
                 .includes(:order)
                 .order(:issued_at, :id)

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
