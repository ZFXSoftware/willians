namespace :fiscal do
  desc "A substituição tributária vem zerada ou vem AUSENTE nas notas do Tiny? (SOMENTE LEITURA)"
  task st_das_notas: :environment do
    # A apuração deu R$ 0,00 de ST em 6.386 notas. Três coisas diferentes
    # produzem esse mesmo zero, e elas pedem providências opostas:
    #
    #   1. a chave `valor_icms_st` existe e vale zero  -> medição: não há ST
    #   2. a chave não existe no nosso banco           -> perdemos na gravação
    #   3. a API do Tiny não manda o campo             -> nunca tivemos o dado
    #
    # Nos casos 2 e 3 a apuração está afirmando "sem ST" sobre coisa que ela não
    # sabe — e é justamente isso que o `indefinido` existe para evitar. Como
    # `nil.to_d` é zero, os três casos são indistinguíveis olhando o resultado.
    #
    # Por isso duas medições: o que está GRAVADO, contando presença da chave
    # separada do valor dela; e o que a API RESPONDE agora, para uma nota só.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    escopo = Invoice
               .where(tenant_id: tenant.id)
               .where("jsonb_typeof(invoices.metadata->'fiscal') = 'object'")

    puts "1) O que está GRAVADO, por origem:"
    puts

    # `jsonb_exists` e não o operador `?`: o `?` numa string de SQL é lido pelo
    # ActiveRecord como placeholder de bind e estoura antes de chegar ao banco.
    # A função faz o mesmo — distinguir "chave ausente" de "chave com valor
    # nulo", que é a distinção em jogo aqui, e que o `->>` não faz porque devolve
    # NULL nos dois casos.
    existe = ->(chave) { "jsonb_exists(invoices.metadata->'fiscal', '#{chave}')" }
    [ "tiny", "mercado_livre", nil ].each do |origem|
      grupo = origem ? escopo.where("invoices.metadata->>'origem' = ?", origem)
                     : escopo.where("invoices.metadata->>'origem' IS NULL")

      total = grupo.count

      next if total.zero?

      com_chave = grupo.where(existe.call("valor_icms_st")).count

      com_csosn = grupo.where(existe.call("csosns")).count

      positivas = grupo.where(
        "COALESCE(NULLIF(invoices.metadata->'fiscal'->>'valor_icms_st',''), '0')::numeric > 0"
      ).count

      base_st = grupo.where(
        "COALESCE(NULLIF(invoices.metadata->'fiscal'->>'base_icms_st',''), '0')::numeric > 0"
      ).count

      puts format("  origem %-16s %5d nota(s)", origem || "(sem origem)", total)
      puts format("    tem a chave valor_icms_st:   %5d %s", com_chave,
                  com_chave == total ? "" : "  <- FALTA EM #{total - com_chave}")
      puts format("    tem a chave csosns:          %5d", com_csosn)
      puts format("    valor_icms_st > 0:           %5d", positivas)
      puts format("    base_icms_st > 0:            %5d", base_st)

      # Os valores literais: "0", "0.00" e "" contam a mesma história para a
      # apuração e histórias diferentes sobre a gravação.
      valores = grupo.where(existe.call("valor_icms_st"))
                     .group(Arel.sql("invoices.metadata->'fiscal'->>'valor_icms_st'"))
                     .order(Arel.sql("count(*) DESC"))
                     .limit(6)
                     .count

      valores.each { |valor, quantas| puts format("      valor %-12s %5d", valor.inspect, quantas) }

      puts
    end

    # A segunda medição: a API responde o campo HOJE?
    #
    # Sem isto, "a chave está gravada com zero" ainda deixa de pé a hipótese de
    # o Tiny ter passado a mandar o campo depois da importação — e de estarmos
    # lendo um zero que é só a nossa cópia velha.
    next puts("Use CONSULTAR=1 para perguntar à API do Tiny sobre uma nota.") unless ENV["CONSULTAR"] == "1"

    nota = escopo.where("invoices.metadata->>'origem' = 'tiny' OR invoices.metadata->>'origem' IS NULL")
                 .where.not(external_id: nil)
                 .order(Arel.sql("RANDOM()"))
                 .first

    next puts("Nenhuma nota do Tiny com external_id para consultar.") if nota.blank?

    puts "2) O que a API do Tiny RESPONDE agora, para a NF #{nota.number}/#{nota.series}:"
    puts

    detalhe = Fiscal::Tiny::V2Client.new.obter_nota(nota.external_id)

    # Só as chaves de tributo, e só nome e valor. O detalhe traz o comprador
    # inteiro, e nada disso precisa aparecer num diagnóstico.
    interessantes = detalhe.to_h.select do |chave, _|
      chave.to_s.match?(/icms|ipi|pis|cofins|issqn|st\b|tributo|regime|crt/i)
    end

    if interessantes.any?
      interessantes.sort.each { |chave, valor| puts format("  %-28s %s", chave, valor.inspect) }
    else
      puts "  a resposta não traz NENHUMA chave de tributo."
      puts "  Então o zero da apuração não é medição: é campo que nunca veio."
    end

    puts
    puts "  chaves de tributo na resposta: #{interessantes.size} de #{detalhe.to_h.size} no total"
    puts
    puts "Como ler:"
    puts "  chave presente valendo 0  -> não há ST nessas vendas. O zero é medição."
    puts "  chave AUSENTE no banco    -> perdemos na gravação; a apuração está"
    puts "     dizendo 'sem ST' sobre o que não sabe, e essas notas deveriam ser"
    puts "     `indefinido`."
    puts "  API sem o campo           -> nunca tivemos o dado, e o conserto é"
    puts "     pedir outro endpoint ao Tiny, não mexer na apuração."
    puts
    puts "Nada foi gravado."
  end
end
