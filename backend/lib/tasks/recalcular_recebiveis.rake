namespace :conciliacao do
  desc "Recalcula o valor dos recebíveis a partir dos lançamentos (APLICAR=1 grava)"
  task recalcular_recebiveis: :environment do
    # A reimportação NÃO refaz isto.
    #
    # `marketplace:reimportar` pula lançamento cujo `external_id` já existe — é o
    # que impede duplicata — e por isso o `ReceivableEngine` não roda de novo para
    # eles. Os recebíveis cujo valor saiu errado continuam errados depois de
    # reimportar, e foi essa suposição minha que teria deixado o conserto pela
    # metade.
    #
    # O que estava errado: o valor do recebível somava as vendas do PEDIDO, e o
    # Mercado Livre permite dois pagamentos no mesmo pedido. Cada um dos dois
    # recebíveis saía com a soma dos dois — R$ 333,00 para uma venda de R$ 166,50.
    # Medidos 62 pedidos, R$ 9.700,94 de excesso.
    #
    # O motor é idempotente: rodá-lo de novo sobre o mesmo lançamento recalcula o
    # recebível a partir dos lançamentos daquele PAGAMENTO. Nada é criado nem
    # apagado — valores são corrigidos.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    aplicar = %w[true 1].include?(ENV["APLICAR"].to_s.strip.downcase)

    de = ENV["DE"].present? ? Date.parse(ENV["DE"]) : nil

    ate = ENV["ATE"].present? ? Date.parse(ENV["ATE"]) : nil

    # Só os pedidos com MAIS DE UM recebível, que são os afetados. Recalcular a
    # base inteira seria dezenas de milhares de chamadas para consertar 62 casos.
    pedidos = ReceivableUnit
                .where(tenant_id: tenant.id)
                .where.not(order_id: nil)
                .group(:order_id)
                .having("COUNT(*) > 1")
                .count
                .keys

    escopo = FinancialEntry
               .where(tenant_id: tenant.id, entry_type: "sale")
               .where(order_id: pedidos)

    escopo = escopo.where(occurred_at: de.beginning_of_day..) if de

    escopo = escopo.where(occurred_at: ..ate.end_of_day) if ate

    puts aplicar ? "MODO: GRAVANDO" : "MODO: SIMULAÇÃO (use APLICAR=1 para gravar)"
    puts "Pedidos com mais de um recebível: #{pedidos.size}"
    puts "Lançamentos de venda a reprocessar: #{escopo.count}"
    puts

    antes = ReceivableUnit.where(tenant_id: tenant.id, order_id: pedidos).sum(:gross_amount).to_d

    puts format("Soma dos brutos desses recebíveis agora: R$ %.2f", antes)
    puts

    next puts("Nada foi gravado.") unless aplicar

    processados = 0
    falhas = 0

    escopo.find_each do |entry|
      Financeiro::ReceivableEngine.new(financial_entry: entry).call

      processados += 1
    rescue StandardError => e
      falhas += 1

      puts "  ERRO no lançamento #{entry.external_id}: #{e.class} #{e.message}" if falhas <= 5
    end

    depois = ReceivableUnit.where(tenant_id: tenant.id, order_id: pedidos).sum(:gross_amount).to_d

    puts format("Reprocessados: %d · falhas: %d", processados, falhas)
    puts format("Soma dos brutos DEPOIS: R$ %.2f  (diferença R$ %.2f)", depois, (depois - antes))
    puts
    puts "Os repasses afetados ainda guardam o bruto antigo: rode"
    puts "  rake conciliacao:recalcular_repasses TENANT=#{tenant.id} APLICAR=1"
  end
end
