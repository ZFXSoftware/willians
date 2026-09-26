namespace :omie do
  desc "Envia as notas fiscais do Tiny ao OMIE como títulos (SIMULA; use APLICAR=1 para gravar)"
  task enviar_notas: :environment do
    # O OMIE do cliente é novo e vazio; o faturamento dele vive no Tiny. Sem os
    # títulos lá, a conciliação compara o repasse do marketplace com o nada.
    #
    # São milhares de notas, e cada uma vira um título na contabilidade de
    # alguém. Por isso: simula por padrão, aceita LIMITE para provar com uma só,
    # e a trava OMIE_ALLOW_WRITES continua valendo por baixo.
    tenant = Diagnostico::EmpresaAlvo.anunciar!

    aplicar = %w[true 1].include?(ENV["APLICAR"].to_s.strip.downcase)

    limite = ENV["LIMITE"].presence&.to_i

    # DESDE= leva HISTÓRICO, abaixo do marco configurado. É deliberado a cada uso:
    # o marco continua valendo para o ciclo automático, que não vai despachar o
    # passado sozinho. Data inválida aborta em vez de virar `nil` silencioso — nil
    # aqui significaria "use o marco", e a pessoa pensaria que mandou histórico.
    desde =
      if ENV["DESDE"].present?
        begin
          Date.parse(ENV["DESDE"])
        rescue Date::Error
          abort "DESDE inválido: #{ENV['DESDE'].inspect}. Use AAAA-MM-DD."
        end
      end

    puts
    puts "Empresa: ##{tenant.id} #{tenant.name}"
    puts "Notas ainda não enviadas: #{pendentes(tenant)}"
    puts "Limite desta execução: #{limite || 'sem limite'}"

    if desde
      puts
      puts "HISTÓRICO: enviando notas emitidas a partir de #{desde}, ABAIXO do marco"
      puts "configurado. O marco do cliente não foi alterado, e o ciclo automático"
      puts "continua sem enxergar esse período."
      puts "Confira antes se o cliente já lançou #{desde.strftime('%m/%Y')} por outro caminho."
    end
    puts

    if aplicar && limite.nil? && !%w[true 1].include?(ENV["TUDO"].to_s.strip.downcase)
      abort "Recusando enviar TODAS de uma vez sem confirmação. Prove com LIMITE=1 " \
            "primeiro; quando estiver certo, repita com TUDO=1."
    end

    # Falta de configuração é recado para o usuário, não defeito. Deixar a
    # exceção subir imprime vinte linhas de backtrace e esconde a única frase
    # que interessa.
    resumo =
      begin
        Financeiro::EnvioDeNotasAoOmie.new(
          tenant: tenant, dry_run: !aplicar, limite: limite, desde: desde
        ).call
      rescue Financeiro::EnvioDeNotasAoOmie::IndiceIndisponivel => e
        abort "PARADO: #{e.message}"
      rescue Financeiro::EnvioDeNotasAoOmie::ConfiguracaoAusente => e
        abort "FALTA CONFIGURAR: #{e.message}"
      end

    puts "Recusas velhas reabertas: #{resumo[:reabertas]}" if resumo[:reabertas].to_i.positive?
    puts "Previstas:        #{resumo[:previstas]}"
    puts "Enviadas:         #{resumo[:enviadas]}"
    puts "Recusadas por nós: #{resumo[:recusadas_por_nos]}"
    puts "Falhas:           #{resumo[:falhas]}"

    if resumo[:amostra].present?
      puts
      puts "Amostra do que seria enviado:"

      resumo[:amostra].each do |item|
        puts format("  NF %-10s %-40s R$ %s", item[:nf], item[:comprador].to_s[0, 40], item[:valor])
      end
    end

    Array(resumo[:erros]).each { |erro| puts "  ERRO: #{erro}" }

    puts
    puts resumo[:aviso] if resumo[:aviso]

    if resumo[:motivo_da_simulacao] == :escrita_bloqueada
      puts "SIMULAÇÃO: a escrita no OMIE está travada (OMIE_ALLOW_WRITES)."
      puts "Nada foi gravado na contabilidade do cliente."
    elsif !aplicar
      puts "SIMULAÇÃO: rode com APLICAR=1 LIMITE=1 para enviar UMA nota e conferir no OMIE."
    end
  end

  # Conta com o MESMO critério que o envio usa, marco inclusive.
  #
  # Contava sem o marco e dizia "32 não enviadas" enquanto o envio dizia
  # "previstas: 0" — as duas verdadeiras, com réguas diferentes, e juntas
  # parecendo defeito. As 32 eram de julho, anteriores à fronteira configurada.
  def pendentes(tenant)
    marco = Integracoes::Config.get("omie", :envio_a_partir_de, tenant: tenant).presence&.to_date

    total = Invoice.where(tenant_id: tenant.id).nao_enviadas_ao_omie.count

    dentro = Invoice.where(tenant_id: tenant.id).nao_enviadas_ao_omie(marco).count

    fora = total - dentro

    texto = dentro.to_s

    texto += " (#{fora} fora da fronteira de #{marco}, não serão enviadas)" if fora.positive?

    texto
  end
end
