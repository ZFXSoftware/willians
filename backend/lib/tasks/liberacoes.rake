namespace :liberacoes do
  desc "Corrige o status dos lançamentos do relatório de liberações do ML (use APLICAR=1 para gravar)"
  task corrigir_status: :environment do
    # Os lançamentos que entraram antes do conserto ficaram como `pending`,
    # porque o ingestor gravava isso para todos. Reimportar NÃO resolve: a
    # deduplicação por external_id pula o que já existe, então eles ficariam
    # pendentes para sempre — e o BalanceEngine, que só soma `settled`,
    # continuaria mostrando saldo virtual zero.
    #
    # Toda linha do relatório de liberações é dinheiro que já afetou o saldo.
    # Pendente ali não existe: o que ainda vai cair vive em receivable_units.
    #
    # Simula por padrão. Mexer no status de lançamento financeiro sem alguém
    # ver antes o que vai mudar é exatamente o que este projeto não faz.
    aplicar = %w[true 1].include?(ENV["APLICAR"].to_s.strip.downcase)

    alvo = FinancialEntry
             .where(source: :mercado_livre, status: :pending)
             .where("external_id LIKE ?", "MLREL-%")

    total = alvo.count

    puts
    puts "Lançamentos do relatório de liberações ainda como pendentes: #{total}"

    if total.zero?
      puts "Nada a fazer."
      next
    end

    alvo.group(:entry_type).count.sort.each do |tipo, quantos|
      puts format("  %-20s %d", tipo, quantos)
    end

    puts
    puts "Somatório por direção (o que volta a contar no saldo virtual):"

    alvo.group(:direction).sum(:amount).sort.each do |direcao, valor|
      puts format("  %-20s %s", direcao, valor)
    end

    puts

    unless aplicar
      puts "SIMULAÇÃO — nada foi gravado. Rode de novo com APLICAR=1 para aplicar."
      next
    end

    # `settled_at` recebe o instante do próprio evento, e não agora: a data em
    # que o dinheiro caiu é a do relatório.
    atualizados = alvo.update_all("status = 'settled', settled_at = occurred_at, updated_at = NOW()")

    puts "#{atualizados} lançamento(s) marcados como liquidados."
  end
end
