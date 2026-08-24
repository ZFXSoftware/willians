module Marketplace
  # Traz do marketplace para o razão os eventos financeiros da janela.
  #
  # Este era o elo que faltava. O `MarketplaceIngestor` sempre existiu, e o
  # `FinancialIngestionJob` também — mas ninguém os chamava: não havia rota nem
  # agendamento. Na prática, conectar uma conta não importava nada, e a
  # conciliação rodava contra um razão vazio devolvendo `total_entries: 0`, que
  # parece sucesso e não é.
  #
  # Cada conta é isolada: falha de integração em uma não derruba as demais,
  # entra no resumo como falha e fica gravada em `last_sync_error` para
  # aparecer na tela.
  class SincronizacaoService
    JANELA_PADRAO_DIAS = 30

    # O agendador do gateway roda de 5 em 5 minutos, porque a conciliação é
    # barata (lê o banco). A ingestão não é: fala com o marketplace, que tem
    # limite de requisições — e no Mercado Livre chega a gerar um relatório do
    # lado deles. Sem esta trava, um agendador de 5 minutos viraria 288
    # varreduras por dia por conta.
    INTERVALO_MINIMO = 60.minutes

    LOG_PREFIX = "[Sincronizacao]".freeze

    def initialize(
      tenant: nil,
      platform_account: nil,
      start_date: nil,
      end_date: nil,
      forcar: false,
      intervalo_minimo: INTERVALO_MINIMO
    )
      @tenant = tenant

      @platform_account = platform_account

      @end_date = (end_date || Date.current).to_date

      @start_date = (start_date || @end_date - JANELA_PADRAO_DIAS).to_date

      @forcar = forcar

      @intervalo_minimo = intervalo_minimo
    end

    def call
      resultados = contas.map { |conta| sincronizar(conta) }

      {
        start_date: start_date,
        end_date: end_date,
        contas: resultados.size,
        sincronizadas: resultados.count { |r| r[:status] == :ok },
        ignoradas: resultados.count { |r| r[:status] == :ignorada },
        falhas: resultados.count { |r| r[:status] == :falha },
        recebidos: resultados.sum { |r| r[:recebidos].to_i },
        novos: resultados.sum { |r| r[:novos].to_i },
        recusados: resultados.sum { |r| r[:recusados].to_i },
        detalhes: resultados
      }
    end

    private

    attr_reader :tenant,
                :platform_account,
                :start_date,
                :end_date,
                :forcar,
                :intervalo_minimo

    def contas
      return [ platform_account ] if platform_account

      escopo = PlatformAccount.where(status: :active)

      escopo = escopo.where(tenant: tenant) if tenant

      escopo.where(tenant: Tenant.where(status: :active)).includes(:tenant).order(:id)
    end

    def sincronizar(conta)
      motivo = pular?(conta)

      return ignorada(conta, motivo) if motivo

      resumo = Ingestors::MarketplaceIngestor.new(
        tenant: conta.tenant,
        platform_account: conta,
        start_date: start_date,
        end_date: end_date
      ).call

      # A tentativa vale mesmo quando não trouxe nada: é o que impede o
      # agendador de tentar de novo daqui a cinco minutos.
      conta.update_columns(last_synced_at: Time.current, last_sync_error: nil)

      log "conta ##{conta.id} (#{conta.platform}): #{resumo[:received].to_i} recebido(s), " \
          "#{resumo[:created].to_i} novo(s), #{resumo[:skipped].to_i} repetido(s), " \
          "#{resumo[:failed].to_i} recusado(s)"

      {
        platform_account_id: conta.id,
        platform: conta.platform,
        status: :ok,
        recebidos: resumo[:received].to_i,
        novos: resumo[:created].to_i,
        repetidos: resumo[:skipped].to_i,
        # Evento que veio do marketplace e o razão recusou (validação). Some no
        # log se não subir até aqui, e "recebi 300, gravei 280" precisa aparecer.
        recusados: resumo[:failed].to_i
      }
    rescue StandardError => e
      falha(conta, e)
    end

    # => nil para sincronizar, ou o motivo de não sincronizar.
    def pular?(conta)
      unless provider_configurado?(conta)
        return "conta não conectada — autorize o acesso pelo OAuth"
      end

      return nil if forcar

      return nil if conta.last_synced_at.blank?

      return nil if conta.last_synced_at <= intervalo_minimo.ago

      "sincronizada há menos de #{intervalo_minimo.inspect}"
    end

    # Sem provider implementado ou sem credencial, o ingestor cairia no provider
    # de SIMULAÇÃO quando ela estiver ligada — e lançamentos fictícios entrariam
    # no razão como se fossem reais. Melhor não chamar.
    def provider_configurado?(conta)
      nome = Ingestors::MarketplaceIngestor::PROVIDERS[conta.platform.to_s]

      return false if nome.blank?

      nome.constantize.configured?(conta)
    end

    def ignorada(conta, motivo)
      {
        platform_account_id: conta.id,
        platform: conta.platform,
        status: :ignorada,
        motivo: motivo
      }
    end

    def falha(conta, erro)
      mensagem = "#{erro.class}: #{erro.message}"

      Rails.logger.error "#{LOG_PREFIX} conta ##{conta.id} falhou: #{mensagem}"

      # Marca a tentativa junto com o erro: sem isso uma conta com credencial
      # quebrada seria retentada a cada cinco minutos, indefinidamente.
      conta.update_columns(last_synced_at: Time.current, last_sync_error: mensagem.truncate(250))

      {
        platform_account_id: conta.id,
        platform: conta.platform,
        status: :falha,
        erro: erro.message
      }
    end

    def log(mensagem) = Rails.logger.info("#{LOG_PREFIX} #{mensagem}")
  end
end
