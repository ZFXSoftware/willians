class IntegracoesController < ApplicationController
  before_action :require_tenant!

  # Plataformas cuja conexão (OAuth) está pronta. A leitura financeira pode
  # ainda estar pendente — ver os providers.
  IMPLEMENTADAS = %w[mercado_livre shopee amazon].freeze

  def index
    contas = current_tenant
               .platform_accounts
               .includes(:marketplace_credential)
               .order(:platform, :id)

    render json: {
      items: contas.map { |conta| serialize(conta, ultima_sincronizacao[conta.id], lancamentos[conta.id].to_i) },
      resumo: {
        total: contas.size,
        conectadas: contas.count { |c| c.marketplace_credential&.connected? },
        precisam_atencao: contas.count { |c| precisa_atencao?(c) }
      },
      plataformas_implementadas: IMPLEMENTADAS,
      notas_fiscais: notas_fiscais
    }
  end

  private

  # As notas do Tiny não são uma "conta de marketplace", mas respondem à mesma
  # pergunta que esta tela faz: o que já entrou e o que falta entrar.
  #
  # `com_pedido` é o número que importa: nota sem pedido não amarra a corrente
  # pedido -> NF -> título, e é o que sobra quando a empresa tem mais de um
  # marketplace e não dá para saber de qual deles é a nota.
  def notas_fiscais
    escopo = Invoice.where(tenant_id: current_tenant.id)

    {
      configurado: Fiscal::Tiny::Settings.configured?(tenant: current_tenant),
      total: escopo.count,
      com_pedido: escopo.where.not(order_id: nil).count,
      ultima_importacao: escopo.maximum(:updated_at),
      enviadas_ao_omie: escopo.where("invoices.metadata->>'omie_codigo_lancamento' IS NOT NULL").count,
      # O desfecho da última importação, que roda em fila: sem isto a tela só
      # sabe dizer "enfileirado", que é igual para sucesso e para falha.
      ultimo_resultado: current_tenant.metadata["tiny_ultima_importacao"]
    }
  end

  def serialize(conta, sincronizado_em, total_lancamentos)
    credencial = conta.marketplace_credential

    {
      id: conta.id,
      nome: conta.name,
      plataforma: conta.platform,
      status: conta.status,
      external_id: conta.external_id,
      integracao_disponivel: IMPLEMENTADAS.include?(conta.platform),
      conectada: credencial&.connected? || false,
      credencial: credencial && {
        status: credencial.status,
        expira_em: credencial.expires_at,
        renovada_em: credencial.last_refreshed_at,
        erro: credencial.refresh_error
      },
      # Quando a ingestão RODOU. Diferente do último lançamento que entrou: uma
      # conta sem venda nova sincroniza e não cria nada, e antes disso parecia
      # nunca ter sincronizado.
      ultima_sincronizacao: conta.last_synced_at,
      ultimo_lancamento: sincronizado_em,
      # "ok", "pendente" ou "falha". Sem isto a tela só sabia ler a ausência de
      # erro como sucesso, e anunciava importação concluída para uma importação
      # que o marketplace ainda estava preparando.
      status_sincronizacao: conta.last_sync_status,
      erro_de_sincronizacao: conta.last_sync_error,
      lancamentos: total_lancamentos,
      precisa_atencao: precisa_atencao?(conta),
      omie: codigos_omie(conta)
    }
  end

  # O que vale para ESTA conta, e de onde veio.
  #
  # Mostrar só o que foi digitado na conta esconderia metade da verdade: um
  # campo em branco aqui pode estar herdando o padrão da empresa e funcionando
  # perfeitamente. "herdado" é informação, "faltando" é alarme.
  def codigos_omie(conta)
    settings = Omie::Settings.new(tenant: current_tenant, platform_account: conta)

    resolvido = settings.resolved

    {
      cliente_fornecedor_id: conta.metadata["omie_cliente_fornecedor_id"],
      conta_corrente_id: conta.metadata["omie_conta_corrente_id"],
      efetivo: {
        cliente_fornecedor_id: resolvido[:cliente_fornecedor_id],
        conta_corrente_id: resolvido[:conta_corrente_id]
      },
      origem: {
        cliente_fornecedor_id: resolvido[:origem_cliente],
        conta_corrente_id: resolvido[:origem_conta]
      }
    }
  end

  def precisa_atencao?(conta)
    return true unless conta.active?

    # Pendente não pede nada de ninguém: é o marketplace preparando o dado.
    # Marcá-la como "precisa de atenção" ensina o usuário a ignorar o aviso.
    return true if conta.last_sync_status == "falha"

    # Contas sincronizadas antes da coluna existir: ali, erro presente era a
    # única forma de dizer "falhou".
    return true if conta.last_sync_status.blank? && conta.last_sync_error.present?

    credencial = conta.marketplace_credential

    return true if credencial.present? && !credencial.connected?

    IMPLEMENTADAS.include?(conta.platform) && credencial.blank?
  end

  # Uma consulta agregada em vez de uma por conta.
  def ultima_sincronizacao
    @ultima_sincronizacao ||=
      FinancialEntry
        .where(tenant_id: current_tenant.id)
        .group(:platform_account_id)
        .maximum(:created_at)
  end

  def lancamentos
    @lancamentos ||=
      FinancialEntry
        .where(tenant_id: current_tenant.id)
        .group(:platform_account_id)
        .count
  end
end
