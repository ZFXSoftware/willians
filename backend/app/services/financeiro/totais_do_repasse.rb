module Financeiro
  # Recalcula bruto, taxa e líquido de um repasse a partir das alocações que ele tem
  # AGORA.
  #
  # `PayoutEngine#call` sai na primeira linha quando o repasse já existe, então o bruto
  # é gravado uma vez e nunca mais muda. Quando um recebível é marcado como não-venda
  # depois — pedido cancelado, depósito na conta, linha que não era venda — o bruto
  # continua somando o que a conciliação já ignora, e as duas pontas passam a medir
  # coisas diferentes.
  #
  # Em 2026-09-28 eu consertei isso três vezes à mão, com `conciliacao:recalcular_repasses
  # APLICAR=1`. Marcar sem recalcular não conserta nada, e lembrar de rodar uma tarefa
  # não é conserto — é processo.
  class TotaisDoRepasse
    # Repasse sem venda nenhuma é SAQUE de saldo acumulado, e o valor dele é o que saiu
    # pelo extrato — não zero.
    #
    # Zerar aqui apagaria da tela R$ 3.102,00 que saíram de verdade da conta do cliente.
    # `PayoutEngine#create_payout!` usa o extrato como piso pelo mesmo motivo, e as duas
    # contas têm que concordar: se divergirem, o repasse muda de valor a cada recálculo.
    def self.para(payout)
      unidades = payout
                   .financial_entry_allocations
                   .filter_map(&:receivable_unit)
                   .uniq
                   .reject(&:nao_e_venda?)

      bruto = soma(unidades, :gross_amount)

      liquido = soma(unidades, :net_amount)

      # Só a LIQUIDAÇÃO serve de piso: é ela que diz quanto saiu da conta.
      #
      # Sem conferir o tipo, o lançamento de uma venda qualquer pendurado no lote viraria
      # o valor do repasse — e um repasse que ficou sem venda passaria a valer o preço de
      # um item. `PayoutEngine` cria a liquidação com `entry_type: :settlement`, e é esse
      # o único lançamento que responde à pergunta.
      entrada = payout.financial_entry

      piso = entrada&.entry_type.to_s == "settlement" ? entrada.amount.to_d : BigDecimal("0")

      {
        gross_amount: bruto.positive? ? bruto : piso,
        fee_amount: soma(unidades, :fee_amount),
        net_amount: liquido.positive? ? liquido : piso
      }
    end

    # Grava só quando muda, e devolve se mudou. Sem a comparação, toda volta do
    # agendador tocaria `updated_at` de todos os repasses.
    def self.gravar!(payout)
      totais = para(payout)

      return false if (payout.gross_amount.to_d - totais[:gross_amount]).abs < BigDecimal("0.01") &&
                      (payout.net_amount.to_d - totais[:net_amount]).abs < BigDecimal("0.01")

      payout.update!(totais)

      true
    end

    def self.soma(unidades, campo)
      unidades.sum(BigDecimal("0")) { |unidade| unidade.public_send(campo).to_d }
    end

    private_class_method :soma
  end
end
