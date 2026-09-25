namespace :fiscal do
  desc "Conciliação fiscal: receita bruta por mês e canal, segregada por tributação (SOMENTE LEITURA)"
  task apuracao: :environment do
    # A tela vem depois disto, de propósito: desenhar coluna para um número que
    # eu não vi é como eu errei três vezes hoje. Primeiro os números reais.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    de = ENV["DE"].present? ? Date.parse(ENV["DE"]) : nil

    ate = ENV["ATE"].present? ? Date.parse(ENV["ATE"]) : nil

    resultado = Fiscal::Apuracao.new(tenant: tenant, de: de, ate: ate).call

    puts "Período: #{resultado[:periodo][:de]} a #{resultado[:periodo][:ate]}"
    puts

    # O regime primeiro, porque é ele que decide se esta conta é a certa. Simples
    # apura sobre receita bruta; se aparecer regime 3 (normal), a nota TEM
    # imposto e a apuração precisa de outra conta.
    puts "Regime tributário das notas:"
    if resultado[:regimes].any?
      resultado[:regimes].sort_by { |_, q| -q }.each do |regime, quantas|
        rotulo = { "1" => "Simples Nacional", "2" => "Simples — excesso de sublimite",
                   "3" => "Regime Normal", "simples" => "Simples Nacional" }[regime.to_s] || regime
        puts format("  %-32s %5d nota(s)", rotulo, quantas)
      end
    else
      puts "  nenhuma nota informa o regime — sem isso não sei se esta conta serve"
    end
    puts

    cobertura = resultado[:cobertura]

    puts "Cobertura do detalhe fiscal:"
    puts format("  notas de venda:            %6d", cobertura[:notas])
    puts format("  com bloco fiscal:          %6d", cobertura[:com_bloco_fiscal])
    puts format("  SEM bloco fiscal:          %6d   R$ %.2f de receita sem detalhe",
                cobertura[:sem_bloco_fiscal], cobertura[:receita_sem_detalhe].to_d)
    puts

    puts "Retido de imposto pelo marketplace, pelo extrato dele:"
    puts format("  R$ %.2f", resultado[:retido_pelo_marketplace].to_d)
    puts "  (zero aqui é resposta, não falta de dado: o Mercado Livre não retém"
    puts "   imposto do vendedor. O que ele desconta é comissão e frete.)"
    puts

    puts format("  %-9s %5s %14s %14s %14s %14s %14s",
                "mês", "notas", "receita bruta", "devoluções", "com ST", "sem ST", "indefinido")

    resultado[:meses].each do |mes|
      puts format("  %-9s %5d %14.2f %14.2f %14.2f %14.2f %14.2f",
                  mes[:mes], mes[:notas], mes[:receita_bruta].to_d,
                  mes[:devolucoes][:valor].to_d,
                  mes[:segregacao][:com_st][:receita].to_d,
                  mes[:segregacao][:sem_st][:receita].to_d,
                  mes[:segregacao][:indefinido][:receita].to_d)
    end

    total = resultado[:total]

    puts format("  %-9s %5d %14.2f %14s %14.2f %14.2f %14.2f",
                "TOTAL", total[:notas], total[:receita_bruta].to_d, "",
                total[:segregacao][:com_st][:receita].to_d,
                total[:segregacao][:sem_st][:receita].to_d,
                total[:segregacao][:indefinido][:receita].to_d)
    puts

    puts "Impostos DENTRO das notas, no período:"
    total[:impostos_na_nota].each do |imposto, valor|
      puts format("  %-10s R$ %.2f", imposto, valor.to_d)
    end
    puts "  (no Simples estes saem zero na NF-e, por isso a apuração é sobre a"
    puts "   RECEITA. vTotTrib não entra aqui: é estimativa do IBPT, não imposto pago.)"
    puts

    puts "Receita por canal, no mês mais recente:"
    ultimo = resultado[:meses].last

    if ultimo
      puts "  #{ultimo[:mes]}:"
      ultimo[:por_canal].each do |canal|
        puts format("    %-34s %5d nota(s)  R$ %12.2f", canal[:rotulo], canal[:notas], canal[:receita].to_d)

        canal[:intermediadores].each { |nome| puts format("        intermediador sem mapa: %s", nome) }
      end
    end

    puts
    puts "Como usar:"
    puts "  a base do PGDAS é a receita bruta do mês; a parcela COM ST entra"
    puts "     segregada, porque o ICMS dela já foi recolhido antes."
    puts "  INDEFINIDO é o que precisa de trabalho: nota sem detalhe fiscal não"
    puts "     pode ser declarada num lado nem no outro por adivinhação."
    puts "  intermediador sem mapa deixa a receita fora de qualquer canal —"
    puts "     mapeie na tela de canais."
    puts
    puts "Nada foi gravado."
  end
end
