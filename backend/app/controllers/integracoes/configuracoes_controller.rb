module Integracoes
  # Tela de configurações das integrações: é aqui que as chaves de API entram
  # no sistema, em vez de viverem no .env do servidor.
  #
  # Segredo gravado nunca volta pela API — a resposta traz só os últimos
  # caracteres, o suficiente para conferir que é a chave certa.
  class ConfiguracoesController < ApplicationController
    before_action :require_tenant!

    before_action :authorize_write!, only: %i[update destroy]

    before_action :carregar_provedor, only: %i[update destroy]

    def index
      render json: {
        provedores: Catalogo.provedores.map { |p| serialize(p) },
        urls_de_retorno: urls_de_retorno
      }
    end

    def update
      valores = params.require(:valores).permit!.to_h

      desconhecidos = valores.keys - @provedor.campos.map(&:chave)

      if desconhecidos.any?
        return render json: { error: "Campos desconhecidos: #{desconhecidos.join(', ')}" },
                      status: :unprocessable_content
      end

      ActiveRecord::Base.transaction { valores.each { |chave, valor| gravar(chave, valor) } }

      Config.limpar_cache(current_tenant, @provedor.chave)

      render json: serialize(@provedor)
    end

    def destroy
      Catalogo.campo_de!(@provedor.chave, params[:chave])

      IntegrationSetting
        .where(tenant_id: current_tenant.id, provider: @provedor.chave, key: params[:chave])
        .destroy_all

      Config.limpar_cache(current_tenant, @provedor.chave)

      render json: serialize(@provedor)
    end

    private

    def carregar_provedor
      @provedor = Catalogo.provedor(params[:provedor])

      render json: { error: "Integração desconhecida: #{params[:provedor]}" }, status: :not_found if @provedor.blank?
    end

    # String vazia significa "apague este campo": é como a tela desfaz uma
    # configuração e volta a valer o que estiver no ambiente.
    def gravar(chave, valor)
      Catalogo.campo_de!(@provedor.chave, chave)

      registro = IntegrationSetting.find_or_initialize_by(
        tenant_id: current_tenant.id, provider: @provedor.chave, key: chave.to_s
      )

      return registro.destroy if valor.to_s.strip.empty?

      registro.update!(value: valor.to_s.strip, updated_by: current_user)
    end

    def serialize(provedor)
      campos = provedor.campos.map { |campo| serialize_campo(provedor, campo) }

      {
        chave: provedor.chave,
        rotulo: provedor.rotulo,
        ajuda: provedor.ajuda,
        documentacao: provedor.documentacao,
        configurado: Config.configurado?(provedor.chave, tenant: current_tenant),
        campos: campos,
        pendencias: campos.select { |c| c[:obrigatorio] && !c[:preenchido] }.map { |c| c[:rotulo] }
      }
    end

    def serialize_campo(provedor, campo)
      valor = Config.get(provedor.chave, campo.chave, tenant: current_tenant)

      {
        chave: campo.chave,
        rotulo: campo.rotulo,
        ajuda: campo.ajuda,
        tipo: campo.tipo,
        opcoes: campo.opcoes,
        secreto: campo.secreto?,
        obrigatorio: campo.obrigatorio?,
        preenchido: valor.present?,
        origem: Config.origem(provedor.chave, campo.chave, tenant: current_tenant),
        variavel_de_ambiente: campo.env,
        # Segredo sai mascarado; o resto volta inteiro para poder ser editado.
        valor: campo.secreto? ? nil : valor,
        pista: campo.secreto? ? mascarar(valor) : nil
      }
    end

    def mascarar(valor)
      return if valor.blank?

      "#{'•' * 8}#{valor.to_s.last(4)}"
    end

    # A URL de retorno precisa ser cadastrada igualzinha no portal de cada
    # plataforma; mostrá-la evita o erro mais comum da configuração.
    def urls_de_retorno
      {
        "mercado_livre" => segura { Marketplace::MercadoLivre::Settings.redirect_uri },
        "shopee" => segura { Marketplace::Shopee::Settings.redirect_uri },
        "amazon" => segura { Marketplace::Amazon::Settings.redirect_uri }
      }
    end

    def segura
      yield
    rescue StandardError
      nil
    end
  end
end
