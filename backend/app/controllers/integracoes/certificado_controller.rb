module Integracoes
  # Upload do certificado digital A1 da empresa.
  #
  # O arquivo entra e nunca mais sai: não existe rota de download, e o que a
  # API devolve é só o resumo — titular, CNPJ e validade. Um .pfx é a
  # identidade digital da empresa, e devolvê-lo por API seria oferecer a quem
  # tomasse a sessão de um usuário a capacidade de assinar como ela.
  class CertificadoController < ApplicationController
    before_action :require_tenant!

    before_action :authorize_write!, only: %i[create destroy]

    # 100 KB: um .pfx tem alguns kilobytes. Arquivo muito maior é engano ou
    # abuso, e recusar cedo evita carregar lixo na memória para descobrir
    # depois que não é certificado.
    TAMANHO_MAXIMO = 100.kilobytes

    def show
      render json: payload
    end

    def create
      arquivo = params[:arquivo]

      return erro("Escolha o arquivo do certificado (.pfx ou .p12).") if arquivo.blank?

      return erro("Arquivo grande demais para um certificado.") if arquivo.size > TAMANHO_MAXIMO

      return erro("Informe a senha do certificado.") if params[:senha].blank?

      # Substituir é subir de novo: uma empresa tem um certificado, e manter o
      # antigo ao lado do novo criaria dúvida sobre qual assina.
      certificado = CertificadoDigital.find_or_initialize_by(tenant_id: current_tenant.id)

      certificado.assign_attributes(
        arquivo: Base64.strict_encode64(arquivo.read),
        senha: params[:senha]
      )

      if certificado.save
        render json: payload
      else
        erro(certificado.errors.full_messages.to_sentence)
      end
    end

    def destroy
      CertificadoDigital.find_by(tenant_id: current_tenant.id)&.destroy

      render json: payload
    end

    private

    def payload
      certificado = CertificadoDigital.find_by(tenant_id: current_tenant.id)

      {
        configurado: certificado.present?,
        certificado: certificado&.resumo,
        # O aviso vive no backend porque a regra é dele: trinta dias antes é
        # prazo para renovar sem correria, e a tela não deveria precisar saber
        # esse número.
        aviso: aviso(certificado)
      }
    end

    def aviso(certificado)
      return if certificado.blank?

      return "O certificado venceu em #{I18n.l(certificado.valido_ate.to_date)}. " \
             "A leitura fiscal está parada até ele ser substituído." if certificado.vencido?

      dias = certificado.dias_para_vencer

      return if dias.blank? || dias > CertificadoDigital::DIAS_DE_AVISO

      "O certificado vence em #{dias} dia(s). Renove antes: quando ele expira, a " \
      "leitura fiscal para sem aviso."
    end

    def erro(mensagem)
      render json: { error: mensagem }, status: :unprocessable_content
    end
  end
end
