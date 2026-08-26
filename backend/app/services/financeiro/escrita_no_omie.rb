module Financeiro
  # Regras comuns aos serviços que GRAVAM no OMIE.
  #
  # Existe por causa de um risco concreto: sem credencial configurada, o
  # sistema cai no cliente de simulação. Isso é bom para desenvolvimento, mas
  # nos serviços de escrita significaria "baixar" títulos contra um dublê,
  # registrar OmieFinancialMapping como sincronizado e reportar sucesso — sem
  # nada ter acontecido no ERP do cliente.
  #
  # Aqui a simulação passa a ser explícita: sem credencial, o serviço roda
  # SEMPRE em modo de simulação, e o resumo diz por quê.
  module EscritaNoOmie
    # Monta o cliente e decide se a execução é de verdade.
    #
    # Devolve [cliente, dry_run, motivo]
    def self.preparar(tenant:, client:, dry_run:)
      real = client || (Omie::Client.configured?(tenant: tenant) ? Omie::Client.new(tenant: tenant) : Omie::FakeOmieClient.new)

      # Cliente injetado (testes) é tratado como real: quem injeta sabe o que
      # está fazendo, e é assim que a suíte verifica o caminho de escrita.
      sem_credencial = real.is_a?(Omie::FakeOmieClient)

      liberada = Omie::Client.writes_enabled?(tenant: tenant)

      efetivo =
        if sem_credencial
          true
        elsif dry_run.nil?
          !liberada
        elsif client
          # Cliente injetado decide sozinho: não é o OMIE de ninguém, é dublê
          # de teste ou chamador que trouxe o próprio.
          dry_run
        else
          # Pedido explícito de gravar NÃO vence a trava. Quem decide se o
          # sistema pode escrever na contabilidade é a configuração da empresa,
          # não o parâmetro que veio da tela.
          dry_run || !liberada
        end

      # O motivo é por que a execução foi simulada CONTRA a vontade de quem
      # pediu — e não simplesmente que ela foi simulada.
      #
      # Sem o `!liberada`, toda simulação pedida de propósito voltava marcada
      # como "escrita bloqueada". A tela então dizia "nada foi gravado porque
      # está travado" mesmo com as duas chaves ligadas, e escondia os botões de
      # envio, que só aparecem quando não há trava. Destravar não mudava nada
      # na tela, e não havia como descobrir por quê.
      motivo =
        if sem_credencial
          :sem_credencial
        elsif efetivo && !liberada
          :escrita_bloqueada
        end

      [real, efetivo, motivo]
    end

    # Anota no resumo por que a execução foi simulada, para a resposta não
    # dizer só "simulacao: true" e deixar o usuário adivinhando.
    def self.anotar!(resumo, motivo)
      return if motivo.blank?

      resumo[:motivo_da_simulacao] = motivo

      return unless motivo == :sem_credencial

      resumo[:aviso] = "Sem credencial do OMIE para esta empresa: nada foi gravado. " \
                       "Preencha App Key e App Secret em Integrações → Configurações."
    end
  end
end
