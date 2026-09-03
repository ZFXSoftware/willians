module Conciliacoes
  # As vendas que compõem um repasse.
  #
  # A tela mostrava o repasse como um número só — "268 venda(s)" — e o porquê
  # da diferença ficava numa tarefa de terminal. Quem opera precisa abrir o
  # lote e ver quais vendas estão dentro, qual tem nota e qual não tem: é
  # olhando a lista que se descobre que a diferença inteira são as vendas sem
  # NF, e não dinheiro faltando.
  class VendasController < ApplicationController
    before_action :require_tenant!

    # Teto de segurança: um repasse do cliente já tem 268 vendas, e nada impede
    # que tenha mil. A tela mostra o que couber e diz quantas ficaram de fora.
    LIMITE = 300

    def index
      lote = PayoutBatch.find_by(id: params[:repasse_id], tenant_id: current_tenant.id)

      return render json: { error: "Repasse não encontrado" }, status: :not_found if lote.blank?

      unidades = unidades_de(lote)

      render json: {
        total: unidades.size,
        exibidas: [ unidades.size, LIMITE ].min,
        # Somas do conjunto INTEIRO, não só do que foi exibido: um total que
        # muda conforme o teto da lista seria pior que total nenhum.
        totais: totais(unidades),
        items: unidades.first(LIMITE).map { |unidade| serialize(unidade) }
      }
    end

    private

    def unidades_de(lote)
      lote
        .financial_entry_allocations
        .includes(receivable_unit: [ :order, :invoice ])
        .filter_map(&:receivable_unit)
        .uniq
        .sort_by { |unidade| [ unidade.expected_on || Date.new(1970), unidade.id ] }
    end

    # A nota do PACOTE vale por várias vendas: somá-la uma vez por venda
    # inflaria o total das notas e faria a diferença aparecer invertida.
    def totais(unidades)
      notas = unidades.filter_map(&:invoice).uniq

      {
        vendas: unidades.sum(BigDecimal("0")) { |u| u.gross_amount.to_d },
        notas: notas.sum(BigDecimal("0")) { |nota| nota.total_amount.to_d },
        sem_nota: unidades.count { |u| u.invoice.blank? },
        valor_sem_nota: unidades.reject(&:invoice).sum(BigDecimal("0")) { |u| u.gross_amount.to_d }
      }
    end

    def serialize(unidade)
      nota = unidade.invoice

      {
        id: unidade.id,
        pedido: unidade.order&.external_id,
        liberado_em: unidade.expected_on,
        valor: unidade.gross_amount,
        nf: nota&.number,
        serie: nota&.series,
        valor_nf: nota&.total_amount,
        # O canal declarado na própria NF-e. É o que denuncia venda de outro
        # marketplace dentro da conciliação do Mercado Livre.
        canal: nota&.metadata.to_h.dig("intermediador", "nome"),
        # Nota de pacote aparece em mais de uma venda, com o valor do conjunto.
        # Sem dizer isso, a linha parece ter valor de NF maior que a venda.
        pacote: nota.present? && nota.receivable_units.size > 1
      }
    end
  end
end
