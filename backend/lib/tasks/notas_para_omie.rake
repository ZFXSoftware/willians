namespace :omie do
  desc "Envia as notas fiscais do Tiny ao OMIE como títulos (SIMULA; use APLICAR=1 para gravar)"
  task enviar_notas: :environment do
    # O OMIE do cliente é novo e vazio; o faturamento dele vive no Tiny. Sem os
    # títulos lá, a conciliação compara o repasse do marketplace com o nada.
    #
    # São milhares de notas, e cada uma vira um título na contabilidade de
    # alguém. Por isso: simula por padrão, aceita LIMITE para provar com uma só,
    # e a trava OMIE_ALLOW_WRITES continua valendo por baixo.
    tenant = Tenant.find_by(id: ENV["TENANT"]) ||
             Tenant.order(:id).find { |t| Current.with_tenant(t) { Omie::Client.configured? } }

    abort "Nenhuma empresa com chave do OMIE. Use TENANT=<id>." if tenant.blank?

    aplicar = %w[true 1].include?(ENV["APLICAR"].to_s.strip.downcase)

    limite = ENV["LIMITE"].presence&.to_i

    puts
    puts "Empresa: ##{tenant.id} #{tenant.name}"
    puts "Notas ainda não enviadas: #{pendentes(tenant)}"
    puts "Limite desta execução: #{limite || 'sem limite'}"
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
          tenant: tenant, dry_run: !aplicar, limite: limite
        ).call
      rescue Financeiro::EnvioDeNotasAoOmie::ConfiguracaoAusente => e
        abort "FALTA CONFIGURAR: #{e.message}"
      end

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

  def pendentes(tenant)
    Invoice
      .where(tenant_id: tenant.id, operation_type: :sale)
      .where.not(status: :cancelled)
      .where("invoices.metadata->>'omie_codigo_lancamento' IS NULL")
      .count
  end
end
