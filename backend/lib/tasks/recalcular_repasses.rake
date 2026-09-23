namespace :conciliacao do
  desc "Recalcula o valor dos repasses a partir das alocações atuais (APLICAR=1 grava)"
  task recalcular_repasses: :environment do
    # Necessário depois da limpeza das reservas.
    #
    # O valor do repasse é a SOMA dos recebíveis alocados nele, e foi gravado no
    # momento em que o lote nasceu — com as reservas dentro. A limpeza tirou as
    # alocações das reservas, mas o valor gravado ficou onde estava: repasse
    # inflado, e a conciliação comparando esse valor inflado com os títulos do
    # OMIE.
    #
    # `PayoutBatch.create!` não recalcula lote existente, então não basta rodar o
    # motor de repasses de novo.
    #
    # NUNCA grava zero sobre um valor positivo: repasse sem recebível algum
    # continua valendo o que o extrato diz, que é a única coisa aqui que não é
    # estimativa. Zerar um repasse de dinheiro que saiu de verdade seria trocar
    # um erro por um pior.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    aplicar = ENV["APLICAR"].to_s == "1"

    puts aplicar ? "MODO: GRAVANDO" : "MODO: SIMULAÇÃO (use APLICAR=1 para gravar)"
    puts

    lotes = PayoutBatch.where(tenant_id: tenant.id).order(paid_at: :desc)

    puts "Repasses: #{lotes.count}"
    puts

    divergentes = []

    lotes.each do |lote|
      unidades = lote.financial_entry_allocations.filter_map(&:receivable_unit).uniq

      bruto = unidades.sum(BigDecimal("0")) { |u| u.gross_amount.to_d }

      taxa = unidades.sum(BigDecimal("0")) { |u| u.fee_amount.to_d }

      liquido = unidades.sum(BigDecimal("0")) { |u| u.net_amount.to_d }

      gravado = lote.gross_amount.to_d

      next if (gravado - bruto).abs < BigDecimal("0.01")

      divergentes << {
        lote: lote,
        unidades: unidades.size,
        bruto: bruto,
        taxa: taxa,
        liquido: liquido,
        gravado: gravado,
        zeraria: bruto.zero? && gravado.positive?
      }
    end

    if divergentes.none?
      puts "Todos os repasses batem com as alocações atuais. Nada a recalcular."

      next
    end

    puts "#{divergentes.size} repasse(s) com valor gravado diferente da soma atual:"
    puts

    puts format("  %-6s %-12s %8s %14s %14s %14s",
                "id", "pago em", "vendas", "gravado", "soma atual", "diferença")

    divergentes.sort_by { |d| -(d[:gravado] - d[:bruto]).abs }.first(25).each do |d|
      puts format("  #%-5d %-12s %8d %14.2f %14.2f %14.2f%s",
                  d[:lote].id, d[:lote].paid_at&.to_date, d[:unidades],
                  d[:gravado], d[:bruto], d[:bruto] - d[:gravado],
                  d[:zeraria] ? "  <- ZERARIA" : "")
    end

    puts "  ... (#{divergentes.size - 25} outros)" if divergentes.size > 25
    puts

    zerariam = divergentes.select { |d| d[:zeraria] }

    puts format("Soma do que está gravado:  R$ %.2f", divergentes.sum { |d| d[:gravado] })
    puts format("Soma das alocações atuais: R$ %.2f", divergentes.sum { |d| d[:bruto] })
    puts

    if zerariam.any?
      puts "#{zerariam.size} repasse(s) ficariam em ZERO e por isso NÃO serão tocados:"
      puts "  o dinheiro saiu de verdade; o que falta é o recebível, não o valor."
      puts "  ids: #{zerariam.first(10).map { |d| d[:lote].id }.join(', ')}"
      puts
    end

    alvos = divergentes.reject { |d| d[:zeraria] }

    puts "A recalcular: #{alvos.size}"
    puts

    unless aplicar
      puts "Simulação. Nada foi gravado."
      puts
      puts "Depois de aplicar, rode a conciliação de novo: os repasses mudaram de valor."

      next
    end

    ActiveRecord::Base.transaction do
      alvos.each do |d|
        d[:lote].update!(
          gross_amount: d[:bruto],
          fee_amount: d[:taxa],
          net_amount: d[:liquido]
        )
      end
    end

    puts "#{alvos.size} repasse(s) recalculado(s)."
    puts
    puts "Agora rode a conciliação pela tela, ou `rake conciliacao:remessa TENANT=#{tenant.id}`."
  end
end
