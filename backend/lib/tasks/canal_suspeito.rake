namespace :fiscal do
  desc "O canal de cada nota bate com a origem do dinheiro dela? (SOMENTE LEITURA)"
  task canal_suspeito: :environment do
    # O canal vem do nome do intermediador declarado na NF-e, e o cliente emite
    # venda de BALCÃO com a marca da loja como intermediador. Se ele usar a mesma
    # marca numa venda de marketplace, ela vira "venda própria" por engano.
    #
    # O erro é caro nos dois sentidos: receita atribuída ao canal errado na
    # apuração, e título no OMIE para uma venda que um repasse deveria cobrir —
    # ou o contrário, venda de balcão esperando repasse que nunca vem.
    #
    # O teste é objetivo e não depende do nome: venda de balcão NÃO tem recebível
    # de marketplace. Se uma nota marcada como própria tem recebível ligado a uma
    # conta de plataforma, o mapeamento está errado. E se uma nota de marketplace
    # não tem recebível nenhum, ou ela é balcão mal mapeado, ou é venda que o
    # marketplace ainda não liberou.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    de = ENV["DE"].present? ? Date.parse(ENV["DE"]) : Date.current.beginning_of_month - 2.months

    puts "Notas de venda emitidas desde #{de}."
    puts

    # Materializado uma vez: a segunda passagem (idade da mais antiga sem
    # recebível) percorre a mesma lista, e refazer a consulta por canal seria
    # cinco varreduras da tabela.
    notas = Invoice
              .where(tenant_id: tenant.id, operation_type: :sale)
              .where.not(status: :cancelled)
              .where(issued_at: de.beginning_of_day..)
              .includes(:order)
              .to_a

    # Recebível por nota, numa consulta: são milhares de notas e uma consulta por
    # nota faria disto um diagnóstico que ninguém roda duas vezes.
    contas_por_nota = ReceivableUnit
                        .where(tenant_id: tenant.id)
                        .where.not(invoice_id: nil)
                        .pluck(:invoice_id, :platform_account_id)
                        .group_by(&:first)
                        .transform_values { |pares| pares.map(&:last).compact.uniq }

    plataformas = PlatformAccount.where(tenant_id: tenant.id).pluck(:id, :platform).to_h

    resumo = Hash.new { |h, k| h[k] = { notas: 0, receita: BigDecimal("0"), com_recebivel: 0, plataformas: Hash.new(0) } }

    suspeitas = []

    notas.each do |nota|
      nome = nota.metadata.to_h.dig("intermediador", "nome")

      canal = Fiscal::Tiny::Canal.para(nome, tenant: tenant)

      chave = canal || "(sem canal)"

      linha = resumo[chave]

      linha[:notas] += 1
      linha[:receita] += nota.total_amount.to_d

      contas = contas_por_nota[nota.id].to_a

      next if contas.empty?

      linha[:com_recebivel] += 1

      contas.each { |id| linha[:plataformas][plataformas[id] || "conta ##{id}"] += 1 }

      # A contradição: marcada como venda própria e com dinheiro de marketplace.
      next unless canal == Fiscal::Tiny::Canal::PROPRIA

      suspeitas << [ nota, nome, contas.map { |id| plataformas[id] || "##{id}" } ] if suspeitas.size < 15
    end

    puts format("  %-22s %6s %14s %10s  %s", "canal", "notas", "receita", "c/ dinheiro", "de onde veio o dinheiro")

    resumo.sort_by { |_, linha| -linha[:receita] }.each do |canal, linha|
      origens = linha[:plataformas].sort_by { |_, q| -q }.map { |p, q| "#{p}:#{q}" }.join(" ")

      puts format("  %-22s %6d %14.2f %10d  %s",
                  canal, linha[:notas], linha[:receita], linha[:com_recebivel], origens.presence || "—")
    end

    puts

    propria = resumo[Fiscal::Tiny::Canal::PROPRIA]

    if propria[:notas].zero?
      puts "Nenhuma nota marcada como venda própria no período."
    elsif propria[:com_recebivel].zero?
      puts "VENDA PRÓPRIA CONFERE: #{propria[:notas]} nota(s), R$ #{format('%.2f', propria[:receita])},"
      puts "e NENHUMA tem recebível de marketplace. É balcão mesmo."
    else
      puts "CONTRADIÇÃO: #{propria[:com_recebivel]} de #{propria[:notas]} notas marcadas como venda"
      puts "própria TÊM recebível de marketplace. Venda de balcão não tem repasse."
      puts
      puts "As primeiras:"
      suspeitas.each do |nota, nome, origens|
        puts format("  NF %-10s R$ %10.2f  intermediador %-24s dinheiro de %s",
                    "#{nota.number}/#{nota.series}", nota.total_amount.to_d,
                    nome.to_s.truncate(24), origens.join(", "))
      end
      puts
      puts "O conserto é o mapa da empresa: mapeie esse nome de intermediador para o"
      puts "canal certo na tela de canais. O padrão não vai acertar — o nome é escolha"
      puts "do cliente, não do marketplace."
    end

    # Canal com receita e ZERO dinheiro rastreado não se explica por "ainda não
    # liberou": ou não existe conta conectada daquela plataforma, ou existe e a
    # ingestão nunca trouxe nada. São providências diferentes — autorizar o OAuth
    # contra investigar a sincronização —, e a IDADE da nota mais velha sem
    # recebível separa as duas de "venda recente ainda em trânsito".
    puts
    puts "Canais com receita e pouco ou nenhum dinheiro rastreado:"
    puts

    contas_por_plataforma = PlatformAccount
                              .where(tenant_id: tenant.id)
                              .group_by(&:platform)

    resumo.sort_by { |_, linha| -linha[:receita] }.each do |canal, linha|
      sem_dinheiro = linha[:notas] - linha[:com_recebivel]

      next if sem_dinheiro.zero?

      contas = contas_por_plataforma[canal].to_a

      situacao = if canal == Fiscal::Tiny::Canal::PROPRIA
        "balcão: não tem repasse, e está certo assim"
      elsif contas.empty?
        "NENHUMA conta desta plataforma cadastrada -> conectar a integração"
      elsif contas.none? { |c| c.status == "active" }
        "conta existe mas está #{contas.map(&:status).uniq.join('/')} -> reautorizar"
      else
        "conta ativa (##{contas.map(&:id).join(',')}) -> a ingestão é que não trouxe"
      end

      puts format("  %-22s %5d de %5d nota(s) sem dinheiro · R$ %11.2f",
                  canal, sem_dinheiro, linha[:notas], linha[:receita])
      puts format("      %s", situacao)

      # A mais VELHA sem recebível: venda de ontem sem dinheiro é normal, venda
      # de julho não é.
      velha = notas.select { |nota|
        Fiscal::Tiny::Canal.para(nota.metadata.to_h.dig("intermediador", "nome"), tenant: tenant).to_s == canal.to_s &&
          contas_por_nota[nota.id].to_a.empty?
      }.min_by { |nota| nota.issued_at || Time.current }

      if velha
        dias = velha.issued_at ? (Date.current - velha.issued_at.to_date).to_i : nil

        puts format("      a mais antiga sem dinheiro: NF %s de %s (%s dias)",
                    velha.number, velha.issued_at&.to_date, dias)
      end

      puts
    end

    puts "Nota de marketplace SEM recebível não é necessariamente erro: pode ser venda"
    puts "que a plataforma ainda não liberou. Só vira suspeita se for antiga — e a"
    puts "idade acima é o que diz qual é o caso."
    puts
    puts "Nada foi gravado."
  end
end
