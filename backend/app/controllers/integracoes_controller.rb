class IntegracoesController < ApplicationController
  before_action :require_tenant!

  # Plataformas com provider implementado. As demais aparecem como disponíveis
  # para conectar, mas sem integração pronta.
  IMPLEMENTADAS = %w[mercado_livre].freeze

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
      plataformas_implementadas: IMPLEMENTADAS
    }
  end

  private

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
      ultima_sincronizacao: sincronizado_em,
      lancamentos: total_lancamentos,
      precisa_atencao: precisa_atencao?(conta)
    }
  end

  def precisa_atencao?(conta)
    return true unless conta.active?

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
