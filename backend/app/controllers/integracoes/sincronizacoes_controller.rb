module Integracoes
  # Ingestão avulsa: traz do marketplace para o razão, SEM conciliar contra o
  # OMIE em seguida.
  #
  # Atenção ao tempo. O relatório de liberações do Mercado Pago é gerado de
  # forma assíncrona, e o cliente espera até três minutos por ele — bem mais do
  # que o proxy aguenta numa requisição de navegador. Por isso a TELA não chama
  # esta rota: ela enfileira pelo gateway, que responde 202 na hora. Esta rota
  # existe para uso máquina-a-máquina (worker, console, integração externa),
  # onde esperar é aceitável.
  class SincronizacoesController < ApplicationController
    before_action :require_tenant!, unless: :service_authenticated?

    before_action :authorize_write!

    def create
      resumo = Marketplace::SincronizacaoService.new(**service_args).call

      render json: resumo.merge(status: "ok")
    rescue ActiveRecord::RecordNotFound
      render json: { status: "error", error: "Conta de marketplace não encontrada" }, status: :not_found
    rescue ArgumentError, Date::Error => e
      render json: { status: "error", error: e.message }, status: :bad_request
    end

    private

    def service_args
      {
        tenant: current_tenant,
        platform_account: platform_account,
        start_date: parse_date(params[:start_date]),
        end_date: parse_date(params[:end_date]),
        forcar: ActiveModel::Type::Boolean.new.cast(params[:forcar]) || false
      }.compact
    end

    # Escopado nos tenants acessíveis: pedir a conta de outro cliente devolve
    # 404, e não os dados dele.
    def platform_account
      return if params[:platform_account_id].blank?

      PlatformAccount
        .where(tenant: accessible_tenants)
        .find(params[:platform_account_id])
    end
  end
end
