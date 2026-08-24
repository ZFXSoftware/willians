module Integracoes
  # Remover uma conta de marketplace da empresa.
  #
  # Existe porque conectar a conta ERRADA é fácil: o OAuth autoriza a conta que
  # estiver logada no navegador, e quem tem duas lojas conecta a de sempre sem
  # perceber. Desconectar revoga o token, mas o registro continuava na lista
  # sem nenhuma forma de tirá-lo dali.
  class ContasController < ApplicationController
    before_action :require_tenant!

    before_action :authorize_write!

    rescue_from ActiveRecord::RecordNotFound do
      render json: { error: "Conta não encontrada" }, status: :not_found
    end

    # Se sobrar algum vínculo que o modelo não conhece, o usuário merece saber
    # o que fazer em vez de receber um 500 mudo. O teste de chaves
    # estrangeiras existe para que isto nunca dispare.
    rescue_from ActiveRecord::InvalidForeignKey do |e|
      Rails.logger.error "[Contas] vínculo não previsto ao apagar: #{e.message}"

      render json: {
        error: "Esta conta ainda tem registros ligados a ela e não pôde ser apagada.",
        hint: "Arquive-a: sai da operação sem destruir nada."
      }, status: :unprocessable_entity
    end

    # Apagar leva junto pedidos, lançamentos, conciliações e snapshots
    # (dependent: :destroy). Numa conta que já importou dado isso é destruição
    # silenciosa de histórico financeiro — então só apaga o que está vazio, e
    # o resto se arquiva.
    def destroy
      conta = buscar

      lancamentos = conta.financial_entries.count

      pedidos = conta.orders.count

      if lancamentos.positive? || pedidos.positive?
        return render json: {
          error: "Esta conta já tem histórico importado e não pode ser apagada.",
          hint: "Arquive-a: sai da operação e o histórico continua auditável.",
          lancamentos: lancamentos,
          pedidos: pedidos
        }, status: :unprocessable_entity
      end

      conta.destroy!

      head :no_content
    end

    # Tira da operação sem destruir nada: some da conciliação e da
    # sincronização, e o que já foi importado continua no razão.
    def arquivar
      conta = buscar

      conta.marketplace_credential&.update!(
        status: :revoked, access_token: nil, refresh_token: nil
      )

      conta.update!(status: :inactive)

      render json: { id: conta.id, status: conta.status }
    end

    private

    # Escopado na empresa do contexto: pedir a conta de outro cliente devolve
    # 404, e não os dados dele.
    def buscar
      current_tenant.platform_accounts.find(params[:id])
    end
  end
end
