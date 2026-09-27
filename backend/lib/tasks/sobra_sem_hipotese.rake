namespace :conciliacao do
  desc "As 163 notas em que o bruto excede a mercadoria e nada explica (SOMENTE LEITURA)"
  task sobra_sem_hipotese: :environment do
    # O pente fino nos 35 repasses achou 163 notas em que `bruto > valor_produtos` e nem
    # o frete nem o parcelamento explicam a diferença — R$ 2.543,29, a maior causa que
    # ainda não tem nome.
    #
    # Aqui a sobra é confrontada com TODAS as colunas do relatório que poderiam compô-la,
    # uma por uma e somadas duas a duas. O que fecha em muitos casos vira hipótese
    # nomeada no motor; o que não fecha continua diferença real.
    #
    # O método é o mesmo que nomeou frete e parcelamento: testar candidatos de fonte
    # independente contra a sobra medida, nunca ajustar um número até fechar.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    lotes = PayoutBatch.where(tenant_id: tenant.id).order(:paid_at).to_a

    # Cada candidato é uma coluna do relatório ou um campo da nota, com o nome que ele
    # teria na explicação. `SHIPPING_FEE_AMOUNT` entra em módulo: no relatório ele chega
    # negativo, como dedução, e a pergunta é se o MESMO valor foi somado ao bruto.
    candidatos = lambda do |linha, fiscal, fracao|
      {
        "cupom" => linha["COUPON_AMOUNT"].to_d.abs,
        "frete do relatório" => linha["SHIPPING_FEE_AMOUNT"].to_d.abs,
        "comissão" => linha["MP_FEE_AMOUNT"].to_d.abs,
        "impostos" => linha["TAXES_AMOUNT"].to_d.abs,
        "desconto da nota" => fiscal["valor_desconto"].to_d * fracao,
        "outras da nota" => fiscal["valor_outras"].to_d * fracao
      }
    end

    achados = Hash.new(0)
    valores = Hash.new { |h, k| h[k] = BigDecimal("0") }
    exemplos = Hash.new { |h, k| h[k] = [] }
    sobras = []

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
        bruto_total = totais[nota.id].to_d

        bruto_aqui = vendas.sum(BigDecimal("0")) { |u| u.gross_amount.to_d }

        fracao = bruto_total.positive? ? (bruto_aqui / bruto_total) : BigDecimal("1")

        composicao = Conciliacao::ComposicaoDaVenda.para(
          nota: nota, vendas: vendas, linhas: linhas, fracao: fracao
        )

        next unless composicao.hipotese == :sobra_sem_hipotese

        sobra = composicao.sobra

        fiscal = nota.metadata.to_h["fiscal"].to_h

        # Uma linha só por nota: some as colunas das vendas dela neste repasse.
        linha = vendas.map { |u| linhas[u.external_id].to_h }.reduce(Hash.new(0)) do |acc, l|
          l.each { |k, v| acc[k] = acc[k].to_d + v.to_d if v.to_s.match?(/\A-?[\d.,]+\z/) }
          acc
        end

        opcoes = candidatos.call(linha, fiscal, fracao)

        # Sozinhos, depois somados dois a dois. Mais que isso vira pescaria: com seis
        # candidatos, alguma combinação sempre fecha.
        nome = opcoes.find { |_, v| v.positive? && (sobra - v).abs <= BigDecimal("0.10") }&.first

        nome ||= opcoes.to_a.combination(2).find do |(_, a), (_, b)|
          (a + b).positive? && (sobra - (a + b)).abs <= BigDecimal("0.10")
        end&.map(&:first)&.join(" + ")

        nome ||= "nada explica"

        achados[nome] += 1
        valores[nome] += sobra
        sobras << sobra

        next unless exemplos[nome].size < 3

        exemplos[nome] << format(
          "NF %-10s sobra %8.2f · bruto %9.2f · produtos %9.2f · fr %.4f · cupom %7.2f · frete_rel %7.2f · comissão %7.2f · origem %s",
          nota.number, sobra, composicao.bruto, composicao.produtos, fracao,
          opcoes["cupom"], opcoes["frete do relatório"], opcoes["comissão"],
          nota.metadata.to_h["origem"] || "—"
        )
      end
    end

    if sobras.empty?
      puts "Nenhuma nota com sobra sem hipótese. Nada a investigar."

      next
    end

    puts format("Notas com sobra sem hipótese: %d · R$ %.2f", sobras.size, sobras.sum)
    puts format("  menor %.2f · maior %.2f · mediana %.2f",
                sobras.min, sobras.max, sobras.sort[sobras.size / 2])
    puts

    puts "O que a sobra é, testando candidatos de fonte independente:"
    achados.sort_by { |_, q| -q }.each do |nome, quantas|
      puts format("  %-40s %4d nota(s) · R$ %9.2f", nome, quantas, valores[nome])

      exemplos[nome].each { |linha| puts "      #{linha}" }
    end

    puts
    puts "Como ler:"
    puts "  um candidato explicando a maioria -> vira hipótese nomeada no motor, do mesmo"
    puts "     jeito que frete e parcelamento viraram."
    puts "  `nada explica` dominando -> o bruto traz algo que o relatório não discrimina,"
    puts "     e aí a pergunta é para o Mercado Livre, não para o código."
    puts
    puts "Nada foi gravado."
  end
end
