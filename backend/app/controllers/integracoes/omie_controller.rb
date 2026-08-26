module Integracoes
  # Os cadastros do OMIE, para a tela poder oferecer uma LISTA em vez de um
  # campo de texto onde se cola um código copiado de um terminal.
  class OmieController < ApplicationController
    before_action :require_tenant!

    def opcoes
      itens = Omie::Readers::Opcoes
                .new(tenant: current_tenant)
                .call(tipo: params[:tipo], busca: params[:busca])

      render json: { items: itens }
    rescue Omie::Readers::Opcoes::TipoDesconhecido => e
      render json: { error: e.message }, status: :bad_request
    rescue Omie::Client::ApiError, Omie::Client::TransportError => e
      # Falha de integração é recado acionável, não erro de servidor: o OMIE
      # pode estar fora, ou a chave pode estar errada.
      render json: { error: "O OMIE não respondeu: #{e.message}" }, status: :service_unavailable
    end
  end
end
