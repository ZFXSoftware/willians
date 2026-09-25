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

    # O regime primeiro, porque é ele que decide QUAL conta é a certa: Simples
    # apura sobre receita bruta, Regime Normal apura o imposto da nota. Quem lê
    # precisa saber em que conta está antes de olhar qualquer número.
    puts "Regime tributário, e em que base cada um apura:"
    if resultado[:regimes].any?
      resultado[:regimes].each do |regime|
        conta = { receita: "apura sobre a RECEITA bruta", imposto: "apura o IMPOSTO da nota" }[regime[:base]] ||
                "não sei apurar — precisa ser mapeado"

        puts format("  %-32s %5d nota(s)  R$ %12.2f  %s",
                    regime[:rotulo], regime[:notas], regime[:receita].to_d, conta)

        regime[:valores_crus].each { |cru| puts format("      valor cru não reconhecido: %s", cru.inspect) }
      end
    else
      puts "  nenhuma nota informa o regime — sem isso não sei qual conta serve"
    end
    puts

    base = resultado[:total][:base]

    puts "Base desta apuração: #{base}"
    case base
    when :receita
      puts "  Simples: o número que vale é a receita bruta do mês, e a parcela COM ST"
      puts "  entra segregada no PGDAS. O imposto na nota sai zero — e isso é correto."
    when :imposto
      puts "  Regime Normal: o número que vale é o imposto debitado na nota. A receita"
      puts "  abaixo é contexto, não a apuração."
    when :mista
      puts "  ATENÇÃO: há notas dos DOIS regimes no período. Cada mês apura pela sua"
      puts "  base — veja `por regime` em cada linha. Somar as duas seria inventar."
    else
      puts "  nenhum regime identificado: os números saem, mas eu não sei qual deles"
      puts "  é a apuração. Mapeie o regime antes de usar isto."
    end
    puts

    # A RBT12 antes de tudo no Simples: é ela que decide alíquota e sublimite, e
    # ler a receita do mês sem ela é ler o número menos importante primeiro.
    if [ :receita, :mista ].include?(base)
      rbt12 = resultado[:rbt12]

      puts "Receita bruta dos últimos 12 meses (RBT12), #{rbt12[:de]} a #{rbt12[:ate]}:"
      puts format("  R$ %.2f", rbt12[:receita].to_d)
      puts format("  %s%% do sublimite de ICMS/ISS (R$ %.2f)",
                  rbt12[:percentual_do_sublimite], rbt12[:sublimite_icms].to_d)
      puts format("  %s%% do teto do Simples (R$ %.2f)",
                  rbt12[:percentual_do_teto], rbt12[:teto_simples].to_d)

      unless rbt12[:completo]
        puts
        puts format("  INCOMPLETA: há %d mês(es) de notas, a conta pede 12.", rbt12[:meses_com_dados])
        puts "  Este valor é PISO, não total — não leia como 'longe do teto'."

        if rbt12[:projecao_anual].present?
          puts format("  No ritmo destes meses, doze meses dariam R$ %.2f.", rbt12[:projecao_anual].to_d)
          puts "  Projeção, não apuração: serve para saber se o assunto é urgente."
        end
      end

      puts
      puts "  Quem decide o que fazer com isso é o contador. Aqui só medimos."
      puts
    end

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

    puts "Impostos DENTRO das notas, no período#{base == :imposto ? ' — ESTA é a apuração' : ''}:"
    total[:impostos_na_nota].each do |imposto, valor|
      puts format("  %-12s R$ %.2f", imposto, valor.to_d)
    end
    if base == :receita
      puts "  (no Simples estes saem zero na NF-e, por isso a apuração é sobre a"
      puts "   RECEITA. vTotTrib não entra aqui: é estimativa do IBPT, não imposto pago.)"
    end
    puts

    if resultado[:meses].any? { |mes| mes[:base] == :mista }
      puts "Meses com mais de um regime:"
      resultado[:meses].select { |mes| mes[:base] == :mista }.each do |mes|
        puts "  #{mes[:mes]}:"
        mes[:por_regime].each do |regime|
          puts format("    %-32s %5d nota(s)  R$ %12.2f",
                      regime[:rotulo], regime[:notas], regime[:receita].to_d)
        end
      end
      puts
    end

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
    puts "  no SIMPLES a base do PGDAS é a receita bruta do mês, e a parcela COM ST"
    puts "     entra segregada, porque o ICMS dela já foi recolhido antes."
    puts "  no REGIME NORMAL o que vale é o imposto debitado na nota, com a base"
    puts "     de cálculo ao lado — a receita bruta ali é só contexto."
    puts "  INDEFINIDO é o que precisa de trabalho: nota sem detalhe fiscal não"
    puts "     pode ser declarada num lado nem no outro por adivinhação."
    puts "  intermediador sem mapa deixa a receita fora de qualquer canal —"
    puts "     mapeie na tela de canais."
    puts
    puts "Nada foi gravado."
  end
end
