class PainelController < ApplicationController
  before_action :require_tenant!

  def show
    render json: Painel::Resumo.new(tenant: current_tenant).call
  end
end
