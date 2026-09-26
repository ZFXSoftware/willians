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
    recebiveis = ReceivableUnit
                   .where(tenant_id: tenant.id)
                   .where.not(invoice_id: nil)
                   .pluck(:invoice_id, :platform_account_id, :expected_on)

    contas_por_nota = recebiveis
                        .group_by(&:first)
                        .transform_values { |linhas| linhas.map { |l| l[1] }.compact.uniq }

    # Quando o dinheiro de cada nota foi previsto. Serve para MEDIR o prazo do
    # repasse em vez de supô-lo: "o Mercado Livre paga em duas semanas" é
    # folclore até alguém contar.
    previsto_por_nota = recebiveis
                          .group_by(&:first)
                          .transform_values { |linhas| linhas.filter_map { |l| l[2] }.min }

    plataformas = PlatformAccount.where(tenant_id: tenant.id).pluck(:id, :platform).to_h

    resumo = Hash.new { |h, k| h[k] = { notas: 0, receita: BigDecimal("0"), com_recebivel: 0, plataformas: Hash.new(0) } }

    suspeitas = []

    notas.each do |nota|
      nome = nota.metadata.to_h.dig("intermediador", "nome")

      canal = Fiscal::Tiny::Canal.para(nome, tenant: tenant)

      # A chave é o CANAL CRU, inclusive nil. Antes eu guardava a string
      # "(sem canal)" e depois comparava com `Canal.para(...).to_s`, que devolve
      # "" para nil: nunca batia, e o canal sem mapa saía com R$ 0,00 ao lado de
      # "9 de 9 sem dinheiro". Rótulo é coisa da impressão, não da chave.
      chave = canal

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
                  canal || "(sem canal)", linha[:notas], linha[:receita],
                  linha[:com_recebivel], origens.presence || "—")
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

      contas = canal ? contas_por_plataforma[canal].to_a : []

      situacao = if canal.nil?
        "intermediador NÃO MAPEADO: não é falta de integração, é falta de mapa"
      elsif canal == Fiscal::Tiny::Canal::PROPRIA
        "balcão: não tem repasse, e está certo assim"
      elsif contas.empty?
        "NENHUMA conta desta plataforma cadastrada -> conectar a integração"
      elsif contas.none? { |c| c.status == "active" }
        "conta existe mas está #{contas.map(&:status).uniq.join('/')} -> reautorizar"
      else
        "conta ativa (##{contas.map(&:id).join(',')}) -> a ingestão é que não trouxe"
      end

      # As notas DESTE canal sem recebível ligado, com o valor delas.
      #
      # Antes eu imprimia `linha[:receita]`, que é a receita do CANAL INTEIRO, ao
      # lado de "683 de 3473 sem dinheiro" — convidando a ler R$ 585 mil como o
      # valor não rastreado quando o não rastreado era outro. É o mesmo erro que
      # persegui o dia todo: número certo no lugar que sugere outra pergunta.
      orfas = notas.select do |nota|
        Fiscal::Tiny::Canal.para(nota.metadata.to_h.dig("intermediador", "nome"), tenant: tenant) == canal &&
          contas_por_nota[nota.id].to_a.empty?
      end

      puts format("  %-22s %5d de %5d nota(s) sem dinheiro · R$ %11.2f delas (canal todo: R$ %.2f)",
                  canal || "(sem canal)", sem_dinheiro, linha[:notas],
                  orfas.sum(BigDecimal("0")) { |nota| nota.total_amount.to_d }, linha[:receita])
      puts format("      %s", situacao)

      # A mais VELHA sem recebível: venda de ontem sem dinheiro é normal, venda
      # de julho não é.
      velha = orfas.min_by { |nota| nota.issued_at || Time.current }

      if velha
        dias = velha.issued_at ? (Date.current - velha.issued_at.to_date).to_i : nil

        puts format("      a mais antiga sem dinheiro: NF %s de %s (%s dias)",
                    velha.number, velha.issued_at&.to_date, dias)
      end

      # "Sem dinheiro" mede o VÍNCULO, não a existência do dinheiro: a nota conta
      # como órfã quando nenhum recebível aponta para ela. Se o PEDIDO dela tem
      # recebível, o dinheiro chegou e o elo é que falta — conserto nosso, no
      # religamento. Se o pedido não tem nenhum, o dinheiro não entrou — e aí é
      # ingestão ou é venda que a plataforma não repassou.
      #
      # Sem separar isso, "683 notas sem dinheiro" manda investigar a ingestão
      # quando o problema pode ser só o vínculo.
      if canal != Fiscal::Tiny::Canal::PROPRIA && orfas.any?
        pedidos = orfas.filter_map(&:order_id).uniq

        com_recebivel = ReceivableUnit
                          .where(tenant_id: tenant.id, order_id: pedidos)
                          .distinct
                          .pluck(:order_id)
                          .to_set

        elo, sem_dinheiro_mesmo, sem_pedido = 0, 0, 0

        orfas.each do |nota|
          if nota.order_id.blank?
            sem_pedido += 1
          elsif com_recebivel.include?(nota.order_id)
            elo += 1
          else
            sem_dinheiro_mesmo += 1
          end
        end

        puts format("      o dinheiro chegou e falta o ELO:        %5d  <- conserto nosso", elo)
        puts format("      o pedido não tem recebível nenhum:      %5d  <- ingestão ou não repassado", sem_dinheiro_mesmo)
        puts format("      a nota não está ligada a pedido algum:  %5d", sem_pedido)

        # POR MÊS, porque a data da mais antiga sozinha não distingue "buraco
        # permanente" de "a ingestão começou depois". Se as órfãs se concentram
        # ANTES do primeiro lançamento que temos, o dinheiro não está faltando:
        # nunca foi buscado. São providências opostas — reingerir um período
        # contra investigar a sincronização.
        por_mes = orfas.group_by { |nota| nota.issued_at&.to_date&.strftime("%Y-%m") }
                       .transform_values { |lista| [ lista.size, lista.sum(BigDecimal("0")) { |n| n.total_amount.to_d } ] }

        puts "      órfãs por mês de emissão:"
        por_mes.sort.each do |mes, (quantas, valor)|
          puts format("        %-9s %5d nota(s)  R$ %11.2f", mes || "(sem data)", quantas, valor)
        end

        # O PRAZO MEDIDO, pelas notas deste canal que têm dinheiro: da emissão da
        # nota até a data prevista do recebível. Com ele, "órfã recente" deixa de
        # ser desculpa e passa a ser conta — nota emitida dentro do prazo típico
        # ainda não DEVE ter dinheiro; mais velha que isso é buraco.
        prazos = notas.filter_map do |nota|
          next unless Fiscal::Tiny::Canal.para(nota.metadata.to_h.dig("intermediador", "nome"), tenant: tenant) == canal

          previsto = previsto_por_nota[nota.id]

          next unless previsto && nota.issued_at

          (previsto - nota.issued_at.to_date).to_i
        end.sort

        if prazos.size >= 20
          p50 = prazos[prazos.size / 2]
          p90 = prazos[(prazos.size * 0.9).to_i]

          corte = Date.current - p90

          dentro, atrasadas = orfas.partition { |nota| nota.issued_at && nota.issued_at.to_date > corte }

          puts format("      prazo medido em %d nota(s) pagas: mediana %d dia(s), p90 %d dia(s)",
                      prazos.size, p50, p90)
          puts format("      órfãs emitidas DEPOIS de %s (dentro do prazo): %d · R$ %.2f",
                      corte, dentro.size, dentro.sum(BigDecimal("0")) { |n| n.total_amount.to_d })
          puts format("      órfãs mais VELHAS que o p90 — buraco de verdade:  %d · R$ %.2f",
                      atrasadas.size, atrasadas.sum(BigDecimal("0")) { |n| n.total_amount.to_d })
        else
          puts format("      só %d nota(s) paga(s) neste canal: sem base para medir o prazo", prazos.size)
        end
      end

      puts
    end

    # O PISO da ingestão, para comparar com os meses acima. Se o primeiro
    # lançamento que temos é de agosto e as notas começam em julho, as órfãs de
    # julho são janela não ingerida — e a conciliação daquele período está
    # comparando repasse nenhum com nota que existe.
    puts "Desde quando temos dinheiro de cada conta:"

    PlatformAccount.where(tenant_id: tenant.id).order(:id).each do |conta|
      extremos = FinancialEntry.where(tenant_id: tenant.id, platform_account_id: conta.id)
                               .pick(Arel.sql("MIN(occurred_at), MAX(occurred_at), COUNT(*)"))

      primeiro, ultimo, quantos = extremos

      puts format("  conta #%-4d %-16s %s",
                  conta.id, conta.platform,
                  quantos.to_i.zero? ? "NENHUM lançamento" :
                    "#{quantos} lançamento(s), de #{primeiro&.to_date} a #{ultimo&.to_date}")
    end

    puts
    puts "Nota de marketplace SEM recebível não é necessariamente erro: pode ser venda"
    puts "que a plataforma ainda não liberou. Só vira suspeita se for antiga — e a"
    puts "idade acima é o que diz qual é o caso."
    puts
    puts "Nada foi gravado."
  end
end
