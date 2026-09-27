namespace :conciliacao do
  desc "De onde vêm os centavos: nota por nota, com a MESMA conta que o motor faz (SOMENTE LEITURA)"
  task centavos_do_repasse: :environment do
    # Um repasse com R$ 4,62 de diferença em ~R$ 20 mil tem 99,98% de confiança e
    # aparece como divergente, porque a tolerância é de um CENTAVO. Subir a
    # tolerância esconderia: 4,62 distribuídos em cem notas são 4,6 centavos por
    # nota, muito acima de arredondamento — o rateio arredonda a soma uma vez, não
    # nota por nota, e os dados de origem têm duas casas.
    #
    # Então os centavos têm causa, e esta tarefa procura qual. Ela repete a conta do
    # motor nota por nota, em vez de comparar com o título cru:
    #
    #   interno   = bruto das vendas aqui − parcelamento SE somado ao bruto
    #   esperado  = (título + abatimento − frete) × fração do repasse
    #
    # O abatimento é o MAIOR entre o desconto da nota e o cupom do relatório; o
    # parcelamento só sai quando `bruto − produtos` confirma que estava somado. Se a
    # sonda usasse conta diferente da do motor, mediria a minha suposição — foi o que
    # aconteceu com a primeira versão do `rateio_do_pacote`.
    #
    # O título vem do OMIE, e não de `nota.total_amount`: se o título divergir da nota
    # por centavos em algum caso, usar a nota esconderia exatamente o que procuramos.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    id = ENV["REPASSE"].to_i

    lote = id.positive? ? PayoutBatch.find_by(tenant_id: tenant.id, id: id) : nil

    next puts("Use REPASSE=<id>.") if lote.blank?

    unidades = lote.financial_entry_allocations
                   .filter_map(&:receivable_unit)
                   .uniq
                   .reject(&:nao_e_venda?)

    linhas = FinancialEntry
               .where(tenant_id: tenant.id, external_id: unidades.map(&:external_id))
               .pluck(:external_id, :raw_payload)
               .to_h { |externo, cru| [ externo, cru.is_a?(Hash) ? cru : {} ] }

    por_nota = unidades.select(&:invoice).group_by(&:invoice)

    # A fração, como o motor calcula: o que este repasse levou sobre o total das
    # vendas ligadas à nota.
    totais = ReceivableUnit
               .where(tenant_id: tenant.id, invoice_id: por_nota.keys.map(&:id))
               .group(:invoice_id)
               .sum(:gross_amount)

    puts "Lendo os títulos do OMIE (pode esperar o desbloqueio)..."

    leitor = Omie::Readers::ReceivableTotals.new(client: Omie::Client.new(tenant: tenant))

    titulos = Current.with_tenant(tenant) do
      leitor.call(start_date: lote.paid_at.to_date - 120, end_date: Date.current)
    end

    puts

    tolerancia = Conciliacao::ConciliacaoEngine::TOLERANCIA_DE_ARREDONDAMENTO

    linhas_saida = []

    resumo = { zeradas: 0, com_delta: 0, sem_titulo: 0, sem_produtos: 0 }

    soma_delta = BigDecimal("0")

    por_nota.each do |nota, vendas|
      chave = Omie::Readers::ReceivableTotals.normalizar(nota.number)

      titulo = titulos[chave]

      if titulo.blank?
        resumo[:sem_titulo] += 1

        next
      end

      fiscal = nota.metadata.to_h["fiscal"].to_h

      produtos = fiscal["valor_produtos"].to_d

      resumo[:sem_produtos] += 1 unless produtos.positive?

      bruto = vendas.sum(BigDecimal("0")) { |u| u.gross_amount.to_d }

      total_da_nota = totais[nota.id].to_d

      fracao = total_da_nota.positive? ? (bruto / total_da_nota) : BigDecimal("1")

      cupom = vendas.sum(BigDecimal("0")) do |u|
        linhas[u.external_id].to_h["COUPON_AMOUNT"].to_d.abs
      end

      parcelamento = vendas.sum(BigDecimal("0")) do |u|
        linhas[u.external_id].to_h["FINANCING_FEE_AMOUNT"].to_d.abs
      end

      abatimento = [ fiscal["valor_desconto"].to_d, cupom ].max

      frete = fiscal["valor_frete"].to_d

      # O parcelamento sai do interno só quando a identidade confirma que estava
      # somado ao bruto. É a mesma decisão do motor.
      somado = produtos.positive? && parcelamento.positive? &&
               ((bruto - (produtos * fracao)) - parcelamento).abs <= tolerancia

      interno = bruto - (somado ? parcelamento : BigDecimal("0"))

      esperado = ((titulo + abatimento - frete) * fracao).round(2)

      delta = (interno - esperado).round(2)

      soma_delta += delta

      delta.abs <= BigDecimal("0.01") ? resumo[:zeradas] += 1 : resumo[:com_delta] += 1

      next if delta.abs <= BigDecimal("0.01")

      linhas_saida << [ delta, format(
        "  %-10s %5d %10.2f %10.2f %9.4f %10.2f %9.2f %9.2f %9s %10.2f",
        nota.number, vendas.size, titulo, bruto, fracao, esperado,
        abatimento, frete, somado ? "sai" : "fica", delta
      ) ]
    end

    puts format("Repasse ##{lote.id} · %d nota(s) · bruto gravado R$ %.2f",
                por_nota.size, lote.gross_amount.to_d)
    puts
    puts format("  notas que fecham ao centavo: %5d", resumo[:zeradas])
    puts format("  notas com delta:             %5d", resumo[:com_delta])
    puts format("  sem título no OMIE:          %5d", resumo[:sem_titulo])
    puts format("  sem valor_produtos na nota:  %5d  (nelas o parcelamento fica na base por omissão)",
                resumo[:sem_produtos])
    puts format("  soma dos deltas:             R$ %.2f", soma_delta)
    puts

    if linhas_saida.any?
      puts format("  %-10s %5s %10s %10s %9s %10s %9s %9s %9s %10s",
                  "NF", "vendas", "titulo", "bruto", "fração", "esperado", "abatim.", "frete",
                  "parcel.", "delta")

      linhas_saida.sort_by { |delta, _| -delta.abs }.first(20).each { |_, linha| puts linha }

      puts
      puts "Como ler:"
      puts "  fração != 1,0000 -> nota de pacote: o delta pode ser o rateio, e aí a"
      puts "     soma dos deltas das duas partes é que tem de fechar."
      puts "  `parcel. fica` com valor alto -> a identidade não confirmou, e o"
      puts "     parcelamento ficou dentro do interno. É o candidato mais provável."
      puts "  delta igual em várias notas -> causa comum, não arredondamento."
    else
      puts "  Todas as notas fecham ao centavo. A diferença do repasse vem de fora"
      puts "  delas: venda sem nota, nota sem título, ou recebível que não é venda."
    end

    puts
    puts "Nada foi gravado."
  end
end
