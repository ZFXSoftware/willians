module Integracoes
  class MercadoLivreController < ApplicationController
    # O callback é público por natureza: quem chega nele é o navegador
    # redirecionado pelo Mercado Livre, sem a nossa sessão. A identidade vem do
    # `state`, que é de uso único.
    allow_unauthenticated :callback

    before_action :require_tenant!, only: :autorizar

    before_action :authorize_write!, only: :autorizar

    def autorizar
      resultado = Marketplace::MercadoLivre::Authorization.new(
        tenant: current_tenant,
        user: current_user,
        platform_account: optional_platform_account
      ).call

      render json: resultado
    rescue Marketplace::MercadoLivre::OauthClient::ConfigError,
           Marketplace::MercadoLivre::Settings::MissingPublicUrl => e
      render json: { error: e.message }, status: :service_unavailable
    end

    def callback
      return redirect_with(status: "erro", message: denial_message) if params[:error].present?

      credential = Marketplace::MercadoLivre::Callback.new(
        code: params[:code],
        state: params[:state]
      ).call

      redirect_with(status: "ok", message: mensagem_de(credential))
    rescue Marketplace::MercadoLivre::Callback::InvalidState => e
      redirect_with(status: "erro", message: e.message)
    rescue Marketplace::MercadoLivre::OauthClient::Error => e
      Rails.logger.error "[MercadoLivre] callback: #{e.class} #{e.message}"

      redirect_with(status: "erro", message: e.message)
    end

    private

    # Diz QUAL vendedor foi conectado, e avisa quando não foi o esperado.
    #
    # O OAuth autoriza quem estiver logado no navegador — não quem a pessoa
    # pretendia. Foi assim que o token de uma conta pessoal entrou no lugar do
    # cliente, e a mensagem genérica "Conta conectada" não deu nenhuma pista:
    # o erro só apareceu dias depois, quando os números não fechavam.
    def mensagem_de(credential)
      vendedor = credential.external_user_id

      indicada = optional_platform_account

      if indicada && indicada.id != credential.platform_account_id
        return "Conectado o vendedor #{vendedor}, que é DIFERENTE do vendedor " \
               "#{indicada.external_id} deste card — por isso ele entrou numa conta própria. " \
               "Se você queria reconectar #{indicada.external_id}, saia dessa conta no " \
               "Mercado Livre (ou use uma janela anônima) e conecte de novo."
      end

      "Vendedor #{vendedor} conectado. Confira se é a conta que faz as vendas."
    end

    def optional_platform_account
      return if params[:platform_account_id].blank?

      PlatformAccount
        .where(tenant: accessible_tenants)
        .find(params[:platform_account_id])
    end

    def denial_message
      [params[:error], params[:error_description]].compact_blank.join(": ").presence ||
        "Autorização negada"
    end

    # Devolve o navegador para o frontend. Sem URL pública configurada não há
    # para onde voltar — aí responde JSON mesmo.
    def redirect_with(status:, message: nil)
      redirect_to(
        Marketplace::MercadoLivre::Settings.return_url(status: status, message: message),
        allow_other_host: true
      )
    rescue Marketplace::MercadoLivre::Settings::MissingPublicUrl
      render json: { status: status, message: message },
             status: status == "ok" ? :ok : :unprocessable_entity
    end
  end
end
