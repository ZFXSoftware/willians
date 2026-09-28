namespace :conciliacao do
  desc "Três regimes de base: hoje, valor do pedido como último recurso, valor do pedido primeiro (SOMENTE LEITURA)"
  task valor_do_pedido: :environment do
    # A medição do juro do comprador respondeu 38 de 40: a sobra sem hipótese é
    # `bruto − transaction_amount`, e nesses 38 `transaction_amount == valor_produtos`
    # **e** `== total_amount do pedido`.
    #
    # O `total_amount` do pedido é o campo melhor: é POR PEDIDO, enquanto o
    # `transaction_amount` é por pagamento e no pacote vem com o valor do pacote
    # inteiro (dois casos medidos: 346,66 e 633,65 contra produtos de 173,33 e 126,73).
    # E ele JÁ ESTÁ no nosso banco — `Order#total_amount`, escrito só pela ingestão do
    # Mercado Livre. O Tiny cria pedido sem valor, então não há circularidade: comparar
    # o total do pedido com a nota confronta duas fontes independentes.
    #
    # A pergunta que sobra é ONDE ele entra. Usá-lo como valor da venda muda a BASE, e
    # mudar a base para todo mundo de uma vez foi o que me rendeu 19 resíduos negativos
    # em 35 repasses. Então: os três regimes medidos lado a lado, e a escolha sai do
    # número.
    #
    #   (a) hoje            — frete e parcelamento como hipóteses nomeadas
    #   (b) último recurso  — o pedido só quando nenhuma hipótese fecha
    #   (c) pedido primeiro — o valor do pedido é o valor da venda, sempre
    #
    # `sobra_sem_hipotese` NÃO é subtraída em nenhum regime: subtrair a sobra inteira
    # fecharia tudo por construção.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    lotes = PayoutBatch.where(tenant_id: tenant.id).order(:paid_at).to_a

    puts "Lendo os títulos do OMIE uma vez..."

    leitor = Omie::Readers::ReceivableTotals.new(client: Omie::Client.new(tenant: tenant))

    titulos = Current.with_tenant(tenant) do
      leitor.call(start_date: lotes.first.paid_at.to_date - 120, end_date: Date.current)
    end

    puts

    # Cobertura primeiro: regime que depende de um campo vazio não é regime.
    com_valor = 0
    sem_valor = 0

    regimes = {
      "(a) hoje" => { fecham: 0, delta: BigDecimal("0"), abs: BigDecimal("0") },
      "(b) pedido como ultimo recurso" => { fecham: 0, delta: BigDecimal("0"), abs: BigDecimal("0") },
      "(c) pedido primeiro" => { fecham: 0, delta: BigDecimal("0"), abs: BigDecimal("0") }
    }

    notas_comparadas = 0

    # Quanto o pedido DISCORDA da nota, que é a diferença de verdade que o regime (c)
    # passa a medir. Se ela for grande, o regime esconde problema em vez de revelar.
    discordancias = []

    lotes.each do |lote|
      unidades = lote.financial_entry_allocations
                     .filter_map(&:receivable_unit)
                     .uniq
                     .reject(&:nao_e_venda?)

      por_nota = unidades.select(&:invoice).group_by(&:invoice)

      next if por_nota.empty?

      linhas = FinancialEntry
                 .where(tenant_id: tenant.id, external_id: unidades.map(&:external_id))
                 .pluck(:external_id, :raw_payload)
                 .to_h { |externo, cru| [ externo, cru.is_a?(Hash) ? cru : {} ] }

      totais = ReceivableUnit
                 .where(tenant_id: tenant.id, invoice_id: por_nota.keys.map(&:id))
                 .group(:invoice_id)
                 .sum(:gross_amount)

      por_nota.each do |nota, vendas|
        chave = Omie::Readers::ReceivableTotals.normalizar(nota.number)

        titulo = titulos[chave]

        next if titulo.blank?

        bruto_total = totais[nota.id].to_d

        bruto_aqui = vendas.sum(BigDecimal("0")) { |u| u.gross_amount.to_d }

        fracao = bruto_total.positive? ? (bruto_aqui / bruto_total) : BigDecimal("1")

        composicao = Conciliacao::ComposicaoDaVenda.para(
          nota: nota, vendas: vendas, linhas: linhas, fracao: fracao
        )

        # O valor que o MARKETPLACE diz que esta venda vale, somando os pedidos desta
        # nota neste repasse.
        do_pedido = vendas.sum(BigDecimal("0")) { |u| u.order&.total_amount.to_d }

        do_pedido.positive? ? (com_valor += 1) : (sem_valor += 1)

        notas_comparadas += 1

        esperado = composicao.esperado_para(titulo, fracao)

        # (a) como está hoje.
        delta_a = composicao.delta_para(titulo, fracao)

        # (b) e (c): o interno passa a ser o valor do pedido, rateado.
        interno_pedido = (do_pedido * fracao).round(2)

        delta_pedido = do_pedido.positive? ? (interno_pedido - esperado).round(2) : delta_a

        delta_b = composicao.hipotese == :sobra_sem_hipotese ? delta_pedido : delta_a

        delta_c = delta_pedido

        if do_pedido.positive?
          discordancias << (do_pedido - composicao.produtos).round(2)
        end

        { "(a) hoje" => delta_a,
          "(b) pedido como ultimo recurso" => delta_b,
          "(c) pedido primeiro" => delta_c }.each do |nome, delta|
          regimes[nome][:fecham] += 1 if delta.abs <= BigDecimal("0.01")
          regimes[nome][:delta] += delta
          regimes[nome][:abs] += delta.abs
        end
      end
    end

    puts format("Notas comparadas: %d · com valor no pedido: %d (%.1f%%) · sem valor: %d",
                notas_comparadas, com_valor,
                notas_comparadas.positive? ? (com_valor * 100.0 / notas_comparadas) : 0, sem_valor)
    puts

    puts format("  %-32s %7s %14s %14s", "regime", "fecham", "soma deltas", "soma |deltas|")

    regimes.each do |nome, r|
      puts format("  %-32s %7d %14.2f %14.2f", nome, r[:fecham], r[:delta], r[:abs])
    end

    puts

    if discordancias.any?
      fora = discordancias.count { |d| d.abs > BigDecimal("0.01") }

      puts format("O pedido discorda da nota em %d de %d nota(s) · soma |discordância| R$ %.2f",
                  fora, discordancias.size, discordancias.sum(&:abs))
      puts format("  maior discordância: R$ %.2f · menor: R$ %.2f",
                  discordancias.max_by(&:abs) || 0, discordancias.min_by(&:abs) || 0)
      puts
    end

    puts "Como ler:"
    puts "  (c) com MUITO mais notas fechando e discordância pequena -> o valor do pedido é"
    puts "     a base certa, e frete/parcelamento eram inferências para chegar nele."
    puts "  (c) pior que (b) -> o pedido não serve para todo mundo, e ele fica como último"
    puts "     recurso, só onde nenhuma hipótese fecha."
    puts "  soma de deltas MUITO menor que a soma dos módulos -> positivos e negativos se"
    puts "     cancelando, e o número pequeno esconde erro em vez de medir acerto."
    puts
    puts "Nada foi gravado."
  end
end
