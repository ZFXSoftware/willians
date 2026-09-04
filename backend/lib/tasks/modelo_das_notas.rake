namespace :fiscal do
  desc "De qual modelo são as notas do cliente — 55 (NF-e) ou 65 (NFC-e) (SOMENTE LEITURA)"
  task modelo_das_notas: :environment do
    # A chave de acesso tem 44 dígitos e carrega o modelo nas posições 21-22:
    #
    #   cUF(2) AAMM(4) CNPJ(14) mod(2) serie(3) nNF(9) tpEmis(1) cNF(8) cDV(1)
    #
    # Isso importa porque a distribuição de DF-e só trafega NF-e (55). NFC-e
    # (65) é venda ao consumidor e não aparece por lá — se parte das notas for
    # 65, essa parte nunca virá da SEFAZ, e nenhum ajuste de código muda isso.
    #
    # Nenhuma chamada externa: a resposta está no que já temos.
    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    notas = Invoice.where(tenant_id: tenant.id).where.not(access_key: nil)

    total = Invoice.where(tenant_id: tenant.id).count

    puts "Notas: #{total} · com chave de acesso: #{notas.count}"
    puts

    if notas.none?
      puts "Sem chave de acesso não dá para saber o modelo."

      next
    end

    modelos = Hash.new(0)
    por_canal = Hash.new { |h, k| h[k] = Hash.new(0) }

    notas.find_each do |nota|
      chave = nota.access_key.to_s.gsub(/\D/, "")

      modelo = chave.length == 44 ? chave[20, 2] : "(chave inválida)"

      modelos[modelo] += 1

      canal = nota.metadata.to_h.dig("intermediador", "nome") || "(não lido)"

      por_canal[canal][modelo] += 1
    end

    puts "Modelo:"
    modelos.sort_by { |_, quantas| -quantas }.each do |modelo, quantas|
      puts format("  %-18s %d", NOMES[modelo] || modelo, quantas)
    end

    puts
    puts "Por canal:"

    por_canal.sort_by { |_, contagem| -contagem.values.sum }.each do |canal, contagem|
      detalhe = contagem.map { |modelo, quantas| "#{NOMES[modelo] || modelo}: #{quantas}" }.join(" · ")

      puts format("  %-24s %s", canal, detalhe)
    end

    puts
    puts "Como ler:"
    puts "  modelo 55 (NF-e)  -> circula na distribuição de DF-e."
    puts "  modelo 65 (NFC-e) -> NÃO circula. Essas notas nunca virão da SEFAZ"
    puts "     por esse caminho, independentemente do que a gente construa."
    puts
    puts "Nada foi gravado."
  end

  NOMES = { "55" => "55 (NF-e)", "65" => "65 (NFC-e)", "57" => "57 (CT-e)" }.freeze
end
