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

    # Leva as notas ao OMIE como títulos a receber.
    #
    # `simular` é o padrão de propósito: são milhares de títulos entrando na
    # contabilidade de alguém, e a tela precisa poder mostrar o que ACONTECERIA
    # antes de acontecer. A trava OMIE_ALLOW_WRITES continua valendo por baixo.
    def enviar_ao_omie
      resumo = Financeiro::EnvioDeNotasAoOmie.new(
        tenant: current_tenant,
        dry_run: simular?,
        limite: params[:limite].presence&.to_i
      ).call

      # Uma linha por execução, sempre.
      #
      # Um clique que "pisca e volta ao que estava" não deixava rastro nenhum:
      # nem no log, nem na tela. Sem saber se ele pediu para gravar, se algo
      # foi recusado ou se simplesmente não havia nota, não há o que
      # investigar.
      Rails.logger.info(
        "[EnvioDeNotas] empresa ##{current_tenant.id}: pedido aplicar=#{!simular?} " \
        "limite=#{params[:limite].presence || 'lote'} -> previstas=#{resumo[:previstas].to_i} " \
        "enviadas=#{resumo[:enviadas].to_i} falhas=#{resumo[:falhas].to_i} " \
        "recusadas_por_nos=#{resumo[:recusadas_por_nos].to_i} pendentes=#{resumo[:pendentes].to_i} " \
        "simulacao=#{resumo[:motivo_da_simulacao] || 'não'}"
      )

      render json: resumo.merge(status: "ok", simulado: resumo[:motivo_da_simulacao].present? || simular?)
    rescue Financeiro::EnvioDeNotasAoOmie::ConfiguracaoAusente,
           Financeiro::EnvioDeNotasAoOmie::MuitasFalhas => e
      render json: { status: "error", error: e.message }, status: :unprocessable_content
    end

    # O ciclo automático de uma empresa, sob demanda. É o que o agendador
    # chama; existe como rota para o gateway poder enfileirá-lo.
    def rotina
      resumo = Fiscal::RotinaDeNotas.new(tenant: current_tenant).call

      render json: resumo.merge(status: "ok")
    end

    private

    # Só envia de verdade com pedido EXPLÍCITO. Um parâmetro ausente nunca
    # pode significar "pode gravar no ERP do cliente".
    def simular?
      !ActiveModel::Type::Boolean.new.cast(params[:aplicar])
    end

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
