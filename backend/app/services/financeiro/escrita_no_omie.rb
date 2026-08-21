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

      efetivo =
        if sem_credencial
          true
        elsif dry_run.nil?
          !Omie::Client.writes_enabled?
        else
          dry_run
        end

      motivo =
        if sem_credencial
          :sem_credencial
        elsif efetivo
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
