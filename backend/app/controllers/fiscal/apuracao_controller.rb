module Fiscal
  # A apuração fiscal do período: receita bruta por mês e canal, segregada por
  # tributação, e a RBT12 do Simples.
  #
  # Não pagina: são doze linhas no máximo, uma por mês. Paginar aqui esconderia
  # o total, que é o número que a tela existe para mostrar.
  class ApuracaoController < ApplicationController
    before_action :require_tenant!

    def show
      render json: Fiscal::Apuracao.new(tenant: Current.tenant, de: de, ate: ate).call
    rescue Date::Error, ArgumentError => e
      render json: { error: e.message }, status: :bad_request
    end

    private

    # Data inválida é erro do pedido, não zero silencioso: `Date.parse("ontem")`
    # levanta, e a tela precisa saber que o filtro dela não foi aplicado em vez
    # de ler um período que não pediu.
    def de = params[:de].presence && Date.parse(params[:de])

    def ate = params[:ate].presence && Date.parse(params[:ate])
  end
end
