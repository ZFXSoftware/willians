namespace :omie do
  desc "Envia ao OMIE as notas que ainda não viraram título (SIMULA; APLICAR=1 grava no OMIE)"
  task enviar_notas: :environment do
    # O envio existe no botão da tela e no ciclo, que faz 40 por volta. Com 133
    # pendentes isso são quatro conciliações inteiras só para empurrar a fila.
    #
    # Isto ESCREVE NO OMIE — cria título a receber na contabilidade do cliente.
    # Por isso simula por padrão, e a trava OMIE_ALLOW_WRITES continua valendo
    # por baixo: mesmo com APLICAR=1, sem ela o serviço cai em simulação e diz.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    aplicar = ENV["APLICAR"].to_s == "1"

    limite = (ENV["LIMITE"] || 40).to_i

    puts aplicar ? "MODO: ENVIANDO AO OMIE" : "MODO: SIMULAÇÃO (use APLICAR=1 para enviar)"
    puts "Até #{limite} nota(s) nesta execução."
    puts

    resumo = Financeiro::EnvioDeNotasAoOmie.new(
      tenant: tenant, dry_run: !aplicar, limite: limite
    ).call

    puts "Previstas: #{resumo[:previstas]}"
    puts "Enviadas:  #{resumo[:enviadas]}"
    puts "Recusadas por nós: #{resumo[:recusadas_por_nos]}" if resumo[:recusadas_por_nos].to_i.positive?
    puts "Ainda pendentes:   #{resumo[:pendentes]}"

    if resumo[:amostra].to_a.any?
      puts
      puts "Amostra:"

      resumo[:amostra].first(5).each do |nota|
        puts format("  NF %-10s R$ %8.2f", nota[:nf], nota[:valor].to_d)
      end
    end

    if resumo[:erros].to_a.any?
      puts
      puts "Erros (#{resumo[:erros].size}):"

      resumo[:erros].first(10).each { |erro| puts "  #{erro.to_s.truncate(160)}" }
    end

    puts

    if resumo[:pendentes].to_i.positive?
      puts "Rode de novo para a próxima leva."
    else
      puts "Fila vazia. Rode `rake conciliacao:rodar TENANT=#{tenant.id} SINCRONIZAR=0`."
    end
  end
end
