module Integracoes
  # De qual canal veio cada nota.
  #
  # A NF-e declara quem intermediou a venda, mas o nome é o que o cliente
  # escolheu usar: numa base real apareceram "Mercado Livre", "Shopee",
  # "Magalu", "TikTok" — e "Alma teen", que é venda de balcão emitida como
  # digital por exigência fiscal, e não é marketplace nenhum.
  #
  # Nenhum código adivinha isso. Por isso a tela: o sistema lista os nomes que
  # encontrou nas notas e quem opera diz o que cada um é, uma vez.
  class CanaisController < ApplicationController
    before_action :require_tenant!

    before_action :authorize_write!, only: :update

    def index
      render json: payload
    end

    def update
      Fiscal::Tiny::Canal.mapear!(current_tenant, params.require(:nome), params[:canal])

      render json: payload
    rescue ArgumentError => e
      render json: { error: e.message }, status: :unprocessable_content
    end

    private

    def payload
      encontrados = Fiscal::Tiny::Canal.encontrados(current_tenant)

      {
        items: encontrados,
        opcoes: Fiscal::Tiny::Canal::OPCOES,
        # Enquanto um nome estiver sem canal, as notas dele não viram pedido e
        # não entram em conciliação nenhuma. É pendência, não detalhe.
        sem_canal: encontrados.count { |item| item[:canal].blank? },
        # Quantas notas ainda não foram perguntadas ao Tiny. O ciclo automático
        # lê em lotes, então esta lista cresce sozinha nas primeiras horas.
        aguardando_leitura: Fiscal::Tiny::IntermediadorSync
                              .new(tenant: current_tenant)
                              .pendentes
                              .count
      }
    end
  end
end
