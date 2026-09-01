module Fiscal
  # O ciclo fiscal de uma empresa: trazer as notas do Tiny e levá-las ao OMIE.
  #
  # Existe porque isto é FUNÇÃO do sistema, não migração de uma vez. Enquanto
  # dependia de alguém apertar um botão, cada cliente precisava de uma pessoa
  # lembrando de entrar e clicar — que é a mesma dependência de operador que o
  # terminal impunha, um passo adiante.
  #
  # Cada empresa é isolada, e cada etapa também: o Tiny fora do ar não impede o
  # envio do que já está no banco, e o OMIE recusando não impede a leitura de
  # amanhã.
  class RotinaDeNotas
    JANELA_PADRAO_DIAS = 7

    LOG_PREFIX = "[RotinaDeNotas]".freeze

    def initialize(tenant:, dias: JANELA_PADRAO_DIAS)
      @tenant = tenant

      @dias = dias
    end

    def call
      return { ignorada: "Tiny não configurado" } unless configurado?

      resumo = { canais: ler_intermediadores, importacao: importar, envio: enviar }

      Rails.logger.info "#{LOG_PREFIX} empresa ##{tenant.id}: #{resumo.inspect}"

      resumo
    end

    private

    attr_reader :tenant, :dias

    def configurado?
      Current.with_tenant(tenant) { Tiny::Settings.configured?(tenant: tenant) }
    end

    # De qual canal veio cada nota, lido na própria NF-e.
    #
    # Vem ANTES da importação porque é ele que permite ao InvoiceSync atribuir
    # o pedido ao marketplace certo — sem isso, ele cai na regra antiga, que
    # pôs 23 de 40 notas do cliente na conciliação do Mercado Livre.
    #
    # Em lote: são milhares de notas a uma consulta por segundo, e uma hora não
    # cabe numa volta do ciclo nem num terminal que cai por inatividade. Cada
    # volta lê um pedaço e o progresso fica gravado nota a nota.
    def ler_intermediadores
      Tiny::IntermediadorSync.new(tenant: tenant).call
    rescue StandardError => e
      Rails.logger.error "#{LOG_PREFIX} empresa ##{tenant.id}: leitura de canais falhou: #{e.message}"

      { erro: e.message }
    end

    # Janela curta de propósito: o ciclo roda o tempo todo, e reler 90 dias a
    # cada volta seria milhares de notas para reencontrar as mesmas. O que
    # ficou para trás se resolve pelo botão, com a janela que o usuário quiser.
    def importar
      fim = Date.current

      Tiny::InvoiceSync
        .new(tenant: tenant)
        .call(start_date: fim - dias, end_date: fim)
    rescue StandardError => e
      Rails.logger.error "#{LOG_PREFIX} empresa ##{tenant.id}: leitura do Tiny falhou: #{e.message}"

      { erro: e.message }
    end

    # `automatico: true` é o que liga as duas travas que só valem aqui: exige a
    # data de corte, e se recusa a insistir depois de falhas seguidas.
    #
    # Sem a empresa liberada, isto roda em SIMULAÇÃO e não grava nada — que é o
    # comportamento certo para um cliente que ainda não foi validado.
    def enviar
      Financeiro::EnvioDeNotasAoOmie
        .new(tenant: tenant, automatico: true)
        .call
    rescue Financeiro::EnvioDeNotasAoOmie::SemMarcoInicial,
           Financeiro::EnvioDeNotasAoOmie::ConfiguracaoAusente,
           Financeiro::EnvioDeNotasAoOmie::MuitasFalhas => e
      # Estes três são recado para alguém, não defeito: entram no resumo em vez
      # de virar erro de fila que ninguém lê.
      { pendencia: e.message }
    rescue StandardError => e
      Rails.logger.error "#{LOG_PREFIX} empresa ##{tenant.id}: envio ao OMIE falhou: #{e.message}"

      { erro: e.message }
    end
  end
end
