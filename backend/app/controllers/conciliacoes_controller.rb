class ConciliacoesController < ApplicationController
  def processar
    if ENV["OMIE_APP_KEY"].blank? || ENV["OMIE_APP_SECRET"].blank?
      Rails.logger.warn "Rodando em modo SIMULAÇÃO (sem Omie)"

      Conciliacao::ConciliacaoService.new(omie_client: Omie::FakeOmieClient.new).processar
    else
      client = OmieClient.new(
        app_key: ENV["OMIE_APP_KEY"],
        app_secret: ENV["OMIE_APP_SECRET"]
      )

      Conciliacao::ConciliacaoService.new(omie_client: client).processar
    end

    render json: { status: "ok" }
  end
end