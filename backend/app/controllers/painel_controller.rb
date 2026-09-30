class PainelController < ApplicationController
  before_action :require_tenant!

  def show
    render json: Painel::Resumo.new(tenant: current_tenant).call
  end

  # As séries dos gráficos, num endpoint próprio.
  #
  # Separado do `show` porque são perguntas diferentes e custos diferentes: o resumo
  # responde "quanto tem agora" e abre a tela; isto varre a janela inteira. Junto, toda
  # abertura do painel pagaria as duas.
  def series
    render json: Painel::Series.new(tenant: current_tenant, dias: params[:dias] || 90).call
  end
end
