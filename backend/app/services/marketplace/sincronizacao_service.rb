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
      intervalo_minimo: INTERVALO_MINIMO,
      # Injetáveis para o teste, no mesmo estilo do `client:` dos leitores. O
      # que precisa ser exercitado aqui é a ORDEM das etapas quando o extrato
      # não está pronto, e isso não se prova com rede de verdade.
      ingestor: nil,
      vinculador: nil
    )
      @ingestor = ingestor || Ingestors::MarketplaceIngestor

      @vinculador = vinculador || VinculoDePedidos

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
        # Nem sincronizada nem falha: a plataforma ainda está preparando o dado.
        pendentes: resultados.count { |r| r[:status] == :pendente },
        falhas: resultados.count { |r| r[:status] == :falha },
        recebidos: resultados.sum { |r| r[:recebidos].to_i },
        novos: resultados.sum { |r| r[:novos].to_i },
        recusados: resultados.sum { |r| r[:recusados].to_i },
        detalhes: resultados
      }
    end

    private

    attr_reader :ingestor,
                :vinculador,
                :tenant,
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

      resumo =
        begin
          ingestor.new(
            tenant: conta.tenant,
            platform_account: conta,
            start_date: start_date,
            end_date: end_date
          ).call
        rescue Marketplace::AindaNaoPronto => e
          # O extrato não está pronto — mas o vínculo de pedidos NÃO depende
          # dele: ele fala com a API de pedidos, que está no ar.
          #
          # Deixar a exceção subir daqui abortava o método inteiro e pulava o
          # vínculo. Na conta do cliente o relatório do Mercado Pago ficou
          # "sendo gerado" por quatro dias, e nesses quatro dias nenhum pedido
          # foi ligado e nenhum `pack_id` foi gravado — travando a nota fiscal
          # de 543 vendas por um motivo sem relação nenhuma com elas.
          vincular_pedidos(conta)

          inferir_pacotes(conta)

      # A nota que saiu com o envio. É a fonte mais precisa que temos: casa por
      # CHAVE, não por semelhança.
      notas_do_envio(conta)

          return pendente(conta, e)
        end

      # Antes dos repasses, e depois da ingestão: o extrato identifica cada
      # linha pelo id do PAGAMENTO, e é aqui que ela ganha o PEDIDO — que é por
      # onde a nota fiscal e o título do OMIE se penduram.
      vinculos = vincular_pedidos(conta)

      # Depois do vínculo, e com o mesmo token: descobre o pacote das vendas
      # que ficaram sem nota porque o Mercado Livre devolveu `pack_id` nulo.
      inferir_pacotes(conta)

      # Depois de tudo gravado, e não no after_commit de cada lançamento: o
      # repasse precisa que os recebíveis da mesma leva já existam, e a ordem
      # em que as linhas do extrato chegam não garante isso.
      repasses = fechar_repasses(conta)

      # A tentativa vale mesmo quando não trouxe nada: é o que impede o
      # agendador de tentar de novo daqui a cinco minutos.
      #
      # O resumo vai junto porque a sincronização roda em FILA: a tela dispara
      # e não recebe resposta nenhuma. Sem isto, "quantos lançamentos entraram,
      # quantos pedidos foram ligados" só existia no log do servidor — e
      # perguntar isso é rotina, não diagnóstico.
      registrar(conta, :ok, resumo: {
        "recebidos" => resumo[:received].to_i,
        "novos" => resumo[:created].to_i,
        "repetidos" => resumo[:skipped].to_i,
        "recusados" => resumo[:failed].to_i,
        "pedidos" => vinculos.is_a?(Hash) ? vinculos[:pedidos] : nil,
        "lancamentos_ligados" => vinculos.is_a?(Hash) ? vinculos[:lancamentos_ligados] : nil,
        # A ingestão pode dar certo e o vínculo falhar — foi o que aconteceu, e
        # a tela dizia apenas "concluída". Sem os pedidos, nada liga o dinheiro
        # à nota fiscal, e isso não pode ficar só no log.
        "vinculo_erro" => vinculos.is_a?(Hash) ? vinculos[:erro] : nil,
        "repasses_novos" => repasses.is_a?(Hash) ? repasses[:criados] : nil,
        "periodo" => "#{start_date} a #{end_date}"
      })

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
        recusados: resumo[:failed].to_i,
        vinculos: vinculos,
        repasses: repasses
      }
    rescue Marketplace::AindaNaoPronto => e
      pendente(conta, e)
    rescue StandardError => e
      falha(conta, e)
    end

    # A nota fiscal que saiu com cada envio.
    #
    # Casa por chave de acesso, que é única — identidade, não inferência. Onde
    # isto funciona, dispensa a heurística de CPF e valor.
    #
    # Falhar aqui não derruba a sincronização: é enriquecimento.
    def notas_do_envio(conta)
      return unless provider_de(conta)&.agrupa_pedidos?

      MercadoLivre::NotaDoEnvio.new(tenant: conta.tenant, platform_account: conta).call
    rescue StandardError => e
      Rails.logger.error "#{LOG_PREFIX} conta ##{conta.id}: nota do envio falhou: #{e.message}"

      { erro: e.message }
    end

    # O pacote que o Mercado Livre não informou.
    #
    # Medido contra vendas de pacote conhecido: 18 inferências, 18 certas, 0
    # erradas. A regra recusa o caso ambíguo em vez de chutar, e a procedência
    # fica gravada no pedido.
    #
    # Falhar aqui não pode derrubar a sincronização — é enriquecimento, não
    # ingestão.
    def inferir_pacotes(conta)
      return unless provider_de(conta)&.agrupa_pedidos?

      MercadoLivre::PacotesInferidos.new(tenant: conta.tenant, platform_account: conta).call
    rescue StandardError => e
      Rails.logger.error "#{LOG_PREFIX} conta ##{conta.id}: inferência de pacote falhou: #{e.message}"

      { erro: e.message }
    end

    # Quem precisa deste passo é o PROVIDER quem diz.
    #
    # Era `return unless conta.mercado_livre?`. Certo no efeito e péssimo como
    # forma: no dia em que a Shopee fosse conectada, os lançamentos dela
    # entrariam e nada seria vinculado, sem sinal nenhum. Agora cada plataforma
    # declara se o extrato dela traz o pedido — e Shopee e Amazon trazem, então
    # a ingestão já liga sozinha.
    def vincular_pedidos(conta)
      return unless provider_de(conta)&.vincula_pedidos?

      vinculador.new(
        tenant: conta.tenant,
        platform_account: conta,
        start_date: start_date,
        end_date: end_date
      ).call
    rescue StandardError => e
      Rails.logger.error "#{LOG_PREFIX} conta ##{conta.id}: vínculo de pedidos falhou: #{e.class} #{e.message}"

      { erro: e.message }
    end

    # Fechar os repasses NÃO pode derrubar a ingestão: os lançamentos já estão
    # no razão e valem por si. Sem lote, a conciliação é que fica esperando.
    def fechar_repasses(conta)
      Financeiro::RepassesDoMarketplace.new(
        tenant: conta.tenant,
        platform_account: conta,
        start_date: start_date,
        end_date: end_date
      ).call
    rescue StandardError => e
      Rails.logger.error "#{LOG_PREFIX} conta ##{conta.id}: repasses falharam: #{e.class} #{e.message}"

      { erro: e.message }
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
    # A CLASSE do provider, para perguntar o que a plataforma faz sem precisar
    # de credencial nem de rede.
    def provider_de(conta)
      nome = Ingestors::MarketplaceIngestor::PROVIDERS[conta.platform.to_s]

      nome&.constantize
    end

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

    # O marketplace ainda está preparando o dado. Não é sucesso — não trouxe
    # nada — e não é falha: nada quebrou e nada se perdeu.
    #
    # Marca a tentativa como as outras (senão o agendador de 5 minutos manda
    # gerar o mesmo relatório repetidamente), e deixa o motivo em
    # `last_sync_error` para a tela mostrar. Quem não quiser esperar o próximo
    # ciclo usa "Sincronizar agora", que ignora o intervalo.
    def pendente(conta, erro)
      log "conta ##{conta.id} (#{conta.platform}) aguardando a plataforma: #{erro.message}"

      registrar(conta, :pendente, erro.message)

      {
        platform_account_id: conta.id,
        platform: conta.platform,
        status: :pendente,
        motivo: erro.message
      }
    end

    def falha(conta, erro)
      mensagem = "#{erro.class}: #{erro.message}"

      Rails.logger.error "#{LOG_PREFIX} conta ##{conta.id} falhou: #{mensagem}"

      # Marca a tentativa junto com o erro: sem isso uma conta com credencial
      # quebrada seria retentada a cada cinco minutos, indefinidamente.
      registrar(conta, :falha, mensagem)

      {
        platform_account_id: conta.id,
        platform: conta.platform,
        status: :falha,
        erro: erro.message
      }
    end

    # Um único lugar grava o desfecho, para que status e mensagem nunca fiquem
    # contando histórias diferentes.
    def registrar(conta, status, mensagem = nil, resumo: nil)
      metadata = conta.metadata.merge(
        "ultima_sincronizacao" => {
          "em" => Time.current,
          "status" => status.to_s
        }.merge(resumo&.compact || {})
      )

      conta.update_columns(
        last_synced_at: Time.current,
        last_sync_status: status.to_s,
        last_sync_error: mensagem&.truncate(250),
        metadata: metadata
      )
    end

    def log(mensagem) = Rails.logger.info("#{LOG_PREFIX} #{mensagem}")
  end
end
