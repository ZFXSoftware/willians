class ConciliacoesController < ApplicationController
  before_action :require_tenant!, unless: :service_authenticated?

  before_action :authorize_write!

  def processar
    resumo = Conciliacao::ConciliacaoService.new(**service_args).processar

    if resumo[:simulacao]
      Rails.logger.warn "[Conciliacoes] SIMULAÇÃO (sem credencial do OMIE): " \
                        "#{resumo[:empresas_em_simulacao].join(', ')}"
    end

    render json: resumo.merge(status: "ok")
  rescue ActiveRecord::RecordNotFound
    render json: { status: "error", error: "Conta de marketplace não encontrada" }, status: :not_found
  rescue ArgumentError, Date::Error => e
    render json: { status: "error", error: e.message }, status: :bad_request
  rescue StandardError => e
    Rails.logger.error "[Conciliacoes] Falha: #{e.class} #{e.message}"

    render json: { status: "error", error: e.message }, status: :unprocessable_entity
  end

  private

  def service_args
    {
      tenant: current_tenant,
      platform_account: platform_account,
      start_date: parse_date(params[:start_date]),
      end_date: parse_date(params[:end_date]),
      sincronizar: flag(:sincronizar, padrao: true),
      forcar: flag(:forcar, padrao: false)
    }.compact
  end

  # `false` precisa sobreviver ao `.compact` acima como valor, e o parâmetro
  # chega como string ("false" é truthy em Ruby).
  def flag(nome, padrao:)
    valor = params[nome]

    return padrao if valor.nil?

    ActiveModel::Type::Boolean.new.cast(valor) || false
  end

  # Busca escopada nos tenants acessíveis: pedir a conta de outro cliente
  # devolve 404, não os dados dele.
  def platform_account
    return if params[:platform_account_id].blank?

    PlatformAccount
      .where(tenant: accessible_tenants)
      .find(params[:platform_account_id])
  end

  def parse_date(value)
    return if value.blank?

    Date.parse(value.to_s)
  rescue Date::Error
    raise ArgumentError, "Data inválida: #{value}"
  end
end
