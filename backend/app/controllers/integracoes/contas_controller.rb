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

      if (lancamentos.positive? || pedidos.positive?) && !confirmado?
        return render json: {
          error: "Esta conta já tem histórico importado.",
          hint: "Arquive-a para tirar da operação sem destruir nada, ou confirme para apagar " \
                "de vez junto com o que ela trouxe.",
          lancamentos: lancamentos,
          pedidos: pedidos
        }, status: :unprocessable_entity
      end

      # Apagar com histórico existe porque o caso é real: uma conta conectada
      # por engano importa lançamentos que NUNCA deveriam ter entrado no razão
      # do cliente. Arquivar não serve aí — o dado continua contando no saldo e
      # na conciliação. Mas é destruição em cascata, então só com confirmação
      # explícita, e registrada.
      if lancamentos.positive? || pedidos.positive?
        Rails.logger.warn(
          "[Contas] apagando a conta ##{conta.id} (#{conta.platform} #{conta.external_id}) " \
          "COM histórico: #{lancamentos} lançamento(s) e #{pedidos} pedido(s), " \
          "a pedido do usuário ##{current_user&.id}."
        )
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

    # Códigos do OMIE desta conta de marketplace.
    #
    # Existe porque a tela da empresa tem UM campo de cliente/fornecedor e UM
    # de conta corrente, e quem vende no Mercado Livre, na Amazon e na Shopee
    # precisa de três — cada marketplace é um cliente diferente no OMIE e cai
    # numa conta corrente diferente.
    #
    # A hierarquia do Omie::Settings já previa isto (conta > tela da empresa >
    # metadata do tenant > ambiente); o que não existia era como preencher o
    # nível da conta sem mexer no banco à mão.
    def omie
      conta = buscar

      valores = CAMPOS_OMIE.index_with { |campo| params.dig(:omie, campo) }.compact

      # String vazia APAGA o código da conta, voltando ao padrão da empresa —
      # é a única forma de desfazer sem um botão só para isso.
      metadata = conta.metadata.merge(
        valores.transform_keys { |campo| "omie_#{campo}" }
               .transform_values { |valor| valor.to_s.strip.presence }
      ).compact

      conta.update!(metadata: metadata)

      render json: { id: conta.id, omie: codigos_de(conta) }
    end

    private

    # Confirmação vem no parâmetro, e nunca por omissão: apagar em cascata não
    # pode ser o efeito de uma requisição distraída.
    def confirmado?
      ActiveModel::Type::Boolean.new.cast(params[:confirmar]) || false
    end

    # Só os que fazem sentido variar por marketplace. As categorias
    # transitórias são do plano de contas da empresa e continuam na tela dela.
    CAMPOS_OMIE = %w[cliente_fornecedor_id conta_corrente_id].freeze

    def codigos_de(conta)
      CAMPOS_OMIE.index_with { |campo| conta.metadata["omie_#{campo}"] }
    end

    # Escopado na empresa do contexto: pedir a conta de outro cliente devolve
    # 404, e não os dados dele.
    def buscar
      current_tenant.platform_accounts.find(params[:id])
    end
  end
end
