namespace :repasses do
  desc "Recalcula lotes de repasse que ficaram valendo zero (use APLICAR=1 para gravar)"
  task corrigir_valores: :environment do
    # O `PayoutEngine` é idempotente pela referência do repasse: uma vez criado
    # o lote, sincronizar de novo o encontra e não recalcula nada. Ou seja, os
    # lotes que nasceram zerados continuariam zerados para sempre, e a tela de
    # conciliação seguiria mostrando "Recebido R$ 0,00" para transferências que
    # aconteceram de verdade.
    #
    # Só mexe em lote ZERADO que tem lançamento de liquidação — daí sai o valor
    # que realmente saiu da conta. Lote com recebíveis alocados não é tocado: o
    # valor dele veio da soma dos recebíveis, que é o certo.
    aplicar = %w[true 1].include?(ENV["APLICAR"].to_s.strip.downcase)

    alvo = PayoutBatch
             .where(net_amount: 0)
             .where.not(financial_entry_id: nil)
             .includes(:financial_entry)

    total = alvo.count

    puts
    puts "Lotes de repasse zerados com lançamento de origem: #{total}"

    if total.zero?
      puts "Nada a fazer."
      next
    end

    corrigiveis = alvo.reject { |lote| lote.financial_entry.amount.to_d.zero? }

    puts
    puts "O que muda:"

    corrigiveis.each do |lote|
      puts format("  lote #%-6d %-34s R$ 0,00 -> %s",
                  lote.id, lote.external_id, lote.financial_entry.amount.to_d.to_s("F"))
    end

    ignorados = total - corrigiveis.size

    puts "  (#{ignorados} sem valor no lançamento — esses ficam como estão)" if ignorados.positive?

    puts

    unless aplicar
      puts "SIMULAÇÃO — nada foi gravado. Rode de novo com APLICAR=1 para aplicar."
      next
    end

    corrigiveis.each do |lote|
      valor = lote.financial_entry.amount.to_d

      lote.update!(gross_amount: valor, net_amount: valor)
    end

    puts "#{corrigiveis.size} lote(s) corrigidos."
    puts
    puts "Rode a conciliação de novo para os registros refletirem os valores novos."
  end
end
