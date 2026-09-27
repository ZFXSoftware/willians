namespace :conciliacao do
  desc "O cupom do relatório está refletido na nota? Classifica caso a caso (SOMENTE LEITURA)"
  task reflexo_do_cupom: :environment do
    # A pergunta que decide a última regra da base de comparação.
    #
    # Em sete notas do repasse #17 o cupom do relatório NÃO está na nota: título
    # 184,65 igual ao bruto 184,65, cupom 33,24. Somar o cupom ao esperado cria
    # diferença que não existe. Mas tirar o cupom da regra fez a soma dos 35 repasses
    # SUBIR de R$ 14.029,73 para R$ 22.390,80 — nas outras notas ele ESTÁ refletido.
    #
    # Então existem dois casos e eu não sei o que os distingue. Esta tarefa classifica
    # cada venda com cupom por uma identidade que não depende de escolha:
    #
    #   bruto == produtos            -> a nota NÃO abateu o cupom
    #   bruto - cupom == produtos    -> a nota abateu
    #
    # E mostra, para cada grupo, como o campo `valor_desconto` da nota se comporta:
    # AUSENTE, "0.00" ou positivo. Se o grupo "não abateu" for sempre o de desconto
    # explícito zero, a regra é essa — e deixa de ser palpite.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    # Só vendas com cupom: é nelas que a pergunta existe.
    unidades = ReceivableUnit
                 .where(tenant_id: tenant.id)
                 .where.not(invoice_id: nil)
                 .includes(:invoice)
                 .to_a
                 .reject(&:nao_e_venda?)

    linhas = FinancialEntry
               .where(tenant_id: tenant.id, external_id: unidades.map(&:external_id))
               .pluck(:external_id, :raw_payload)
               .to_h { |externo, cru| [ externo, cru.is_a?(Hash) ? cru : {} ] }

    grupos = Hash.new { |h, k| h[k] = { casos: 0, valor: BigDecimal("0"), descontos: Hash.new(0) } }

    exemplos = Hash.new { |h, k| h[k] = [] }

    unidades.each do |unidade|
      cupom = linhas[unidade.external_id].to_h["COUPON_AMOUNT"].to_d.abs

      next unless cupom.positive?

      nota = unidade.invoice

      fiscal = nota.metadata.to_h["fiscal"].to_h

      produtos = fiscal["valor_produtos"].to_d

      next unless produtos.positive?

      bruto = unidade.gross_amount.to_d

      # Como o campo de desconto se apresenta: a distinção entre AUSENTE e "0.00" é o
      # que pode decidir a regra, e `to_d` apaga as duas em zero.
      estado = if fiscal.key?("valor_desconto")
        fiscal["valor_desconto"].to_d.positive? ? "desconto > 0" : "desconto 0.00"
      else
        "sem campo"
      end

      caso =
        if (bruto - produtos).abs <= BigDecimal("0.02")
          "nota NÃO abateu o cupom"
        elsif (bruto - cupom - produtos).abs <= BigDecimal("0.02")
          "nota abateu o cupom"
        else
          "nenhuma das duas"
        end

      grupo = grupos[caso]

      grupo[:casos] += 1
      grupo[:valor] += cupom
      grupo[:descontos][estado] += 1

      next unless exemplos[caso].size < 4

      exemplos[caso] << format(
        "NF %-10s bruto %9.2f · produtos %9.2f · cupom %8.2f · desconto %-12s · origem %s",
        nota.number, bruto, produtos, cupom,
        fiscal["valor_desconto"].inspect, nota.metadata.to_h["origem"] || "—"
      )
    end

    if grupos.empty?
      puts "Nenhuma venda com cupom e nota com valor_produtos. Nada a classificar."

      next
    end

    grupos.sort_by { |_, g| -g[:casos] }.each do |caso, g|
      puts format("%-26s %5d caso(s) · R$ %10.2f de cupom", caso, g[:casos], g[:valor])

      g[:descontos].sort_by { |_, q| -q }.each do |estado, quantos|
        puts format("    campo da nota: %-14s %5d", estado, quantos)
      end

      exemplos[caso].each { |linha| puts "    #{linha}" }

      puts
    end

    puts "Como ler:"
    puts "  se \"não abateu\" for sempre `desconto 0.00` e \"abateu\" sempre `sem campo`,"
    puts "     a regra é: usar o cupom só quando a nota NÃO informa desconto."
    puts "  se os dois grupos tiverem os mesmos estados, o dado não distingue e a"
    puts "     resposta está fora da nota — provavelmente em quem paga o cupom."
    puts
    puts "Nada foi gravado."
  end
end
