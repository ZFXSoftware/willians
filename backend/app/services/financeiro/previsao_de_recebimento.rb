module Financeiro
  # Briefing 2.3 — o recebível futuro precisa aparecer no fluxo de caixa do
  # OMIE, para que a projeção financeira do cliente seja realista.
  #
  # O título JÁ EXISTE no OMIE (nasce da nota fiscal). O que falta é a data:
  # a nota é emitida na venda, mas o marketplace só libera o dinheiro semanas
  # depois. `data_previsao` é justamente a "Data de Previsão de Recebimento"
  # que alimenta o fluxo de caixa, e é ela que passa a refletir a liberação
  # real do marketplace.
  #
  # ATENÇÃO: diferente da baixa e dos valores sem vínculo, que CRIAM
  # lançamentos, este serviço ALTERA um lançamento existente na contabilidade
  # do cliente. A documentação do OMIE não confirma se AlterarContaReceber
  # preserva os campos não enviados. Por isso o payload é mínimo e explícito, e
  # a recomendação é validar em UM título antes de rodar em lote.
  class PrevisaoDeRecebimento
    ENDPOINT = "financas/contareceber/".freeze

    CALL = "AlterarContaReceber".freeze

    STATUS_ABERTOS = %w[scheduled available partially_paid].freeze

    def initialize(tenant:, client: nil, titulos: nil, dry_run: nil, limite: nil)
      @tenant = tenant

      @client = client || (Omie::Client.configured?(tenant: tenant) ? Omie::Client.new(tenant: tenant) : Omie::FakeOmieClient.new)

      @titulos = titulos

      @dry_run = dry_run.nil? ? !Omie::Client.writes_enabled? : dry_run

      # Trava de segurança: por ser alteração, dá para rodar em poucos títulos
      # primeiro e conferir no OMIE antes de soltar no lote inteiro.
      @limite = limite

      @resumo = Hash.new(0)

      @detalhes = []
    end

    def call
      resumo[:simulacao] = dry_run

      alterados = 0

      recebiveis.find_each do |recebivel|
        break if limite && alterados >= limite

        alterados += 1 if processar(recebivel)
      end

      { resumo: resumo.to_h, detalhes: detalhes }
    end

    private

    attr_reader :tenant, :client, :dry_run, :limite, :resumo, :detalhes

    def indice
      @titulos ||= Omie::Readers::OpenTitles.new(client: client).por_nota_fiscal
    end

    def recebiveis
      ReceivableUnit
        .where(tenant_id: tenant.id, status: STATUS_ABERTOS)
        .where.not(expected_on: nil)
        .where.not(invoice_id: nil)
        .includes(:invoice)
    end

    def processar(recebivel)
      resumo[:recebiveis] += 1

      numero = Omie::Readers::OpenTitles.normalizar_numero(recebivel.invoice&.number)

      candidatos = numero.present? ? (indice[numero] || []) : []

      if candidatos.empty?
        registrar(recebivel, :sem_titulo, "NF #{recebivel.invoice&.number} sem título em aberto")

        return false
      end

      prevista = recebivel.expected_on.strftime("%d/%m/%Y")

      desatualizados = candidatos.reject { |t| t.previsao == prevista }

      if desatualizados.empty?
        registrar(recebivel, :ja_corretos, "previsão já é #{prevista}")

        return false
      end

      desatualizados.each { |titulo| atualizar!(recebivel, titulo, prevista) }

      true
    end

    def atualizar!(recebivel, titulo, prevista)
      if dry_run
        return registrar(recebivel, :atualizaria,
                         "título #{titulo.codigo_lancamento_omie}: #{titulo.previsao.inspect} -> #{prevista}",
                         titulo: titulo)
      end

      client.request(
        ENDPOINT,
        CALL,
        codigo_lancamento_omie: titulo.codigo_lancamento_omie.to_i,
        data_previsao: prevista
      )

      registrar(recebivel, :atualizados,
                "título #{titulo.codigo_lancamento_omie} previsto para #{prevista}",
                titulo: titulo)
    rescue Omie::Client::Error => e
      registrar(recebivel, :falhas, "título #{titulo.codigo_lancamento_omie}: #{e.message}", titulo: titulo)
    end

    def registrar(recebivel, chave, mensagem, titulo: nil)
      resumo[chave] += 1

      detalhes << {
        receivable_unit_id: recebivel.id,
        nota_fiscal: recebivel.invoice&.number,
        previsto_para: recebivel.expected_on,
        resultado: chave,
        mensagem: mensagem,
        codigo_lancamento_omie: titulo&.codigo_lancamento_omie
      }
    end
  end
end
