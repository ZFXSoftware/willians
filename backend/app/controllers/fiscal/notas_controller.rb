module Fiscal
  # Importa as notas fiscais do Tiny para o nosso banco.
  #
  # É a origem do número da NF, que é a chave de casamento com o título do
  # OMIE, e do número do pedido do marketplace — que o relatório de liberações
  # do Mercado Livre não traz.
  #
  # NÃO toca no OMIE: isso é outro passo, com trava própria.
  class NotasController < ApplicationController
    JANELA_PADRAO_DIAS = 30

    before_action :require_tenant!, unless: :service_authenticated?

    before_action :authorize_write!

    def importar
      resumo = Tiny::InvoiceSync
                 .new(tenant: current_tenant)
                 .call(start_date: inicio, end_date: fim)

      render json: resumo.merge(status: "ok", start_date: inicio, end_date: fim)
    rescue Tiny::Settings::MissingConfig => e
      # Falta de configuração é acionável pelo usuário, não erro de servidor.
      render json: { status: "error", error: e.message }, status: :unprocessable_content
    rescue Tiny::V2Client::AuthError => e
      render json: {
        status: "error",
        error: "O Tiny recusou o token: #{e.message}"
      }, status: :unprocessable_content
    rescue ArgumentError, Date::Error => e
      render json: { status: "error", error: e.message }, status: :bad_request
    end

    private

    def fim
      @fim ||= parse_date(params[:end_date]) || Date.current
    end

    def inicio
      @inicio ||= parse_date(params[:start_date]) || (fim - JANELA_PADRAO_DIAS)
    end

    def parse_date(valor)
      return if valor.blank?

      Date.parse(valor.to_s)
    rescue Date::Error
      raise ArgumentError, "Data inválida: #{valor}"
    end
  end
end
