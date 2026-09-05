namespace :tiny do
  desc "Pergunta ao Tiny se ele tem as notas que faltam (SOMENTE LEITURA)"
  task procurar_das_ausentes: :environment do
    # Decide de quem é a providência.
    #
    # 236 vendas têm nota no marketplace e não no nosso banco, com números
    # ABAIXO do menor que importamos. Duas explicações opostas cabem no mesmo
    # fato: ou a janela de importação não foi longe o bastante — e o conserto é
    # nosso, reimportar — ou o Tiny não tem essas notas, e aí foram emitidas em
    # outro sistema, o que é pergunta para o cliente.
    #
    # Perguntar ao Tiny pelo número do PEDIDO separa as duas. Sem isso, mandar
    # reimportar julho inteiro seria chute caro.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    quantos = (ENV["QUANTOS"] || 15).to_i

    # Amostra ALEATÓRIA. Pegar os mais recentes já me enganou quatro vezes
    # nesta base: a ponta da lista não representa o meio dela.
    ausentes = ReceivableUnit
                 .where(tenant_id: tenant.id, invoice_id: nil)
                 .joins(:order)
                 .where("jsonb_typeof(orders.metadata->'nota_do_envio') = 'object'")
                 .includes(:order)
                 .order(Arel.sql("RANDOM()"))
                 .limit(quantos * 3)
                 .to_a

    # Só interessam as que realmente não estão aqui — as canceladas já têm
    # dona.
    ausentes = ausentes.reject do |unidade|
      dados = unidade.order.metadata["nota_do_envio"]

      numero = dados["numero"].to_s.sub(/\A0+/, "")

      Invoice.where(tenant_id: tenant.id)
             .where("regexp_replace(COALESCE(number,''), '\\A0+', '') = ?", numero)
             .exists?
    end.first(quantos)

    puts "Perguntando ao Tiny sobre #{ausentes.size} vendas (amostra aleatória)."
    puts

    next puts("Nenhuma venda nessa situação.") if ausentes.none?

    reader = Fiscal::Tiny::Reader.new

    # CONTROLE, antes de qualquer conclusão.
    #
    # Uma busca quebrada devolve vazio para TODA nota, e "não existe no Tiny"
    # é exatamente como isso se parece. Então primeiro perguntamos por uma nota
    # que veio do Tiny e está no nosso banco: se nem essa for encontrada, o que
    # não presta é a busca, e o resto do relatório não vale nada.
    # E o controle tem de ser da MESMA série investigada. O primeiro que fiz
    # caiu numa nota série 5 e passou, mas as ausentes são todas série 2 — se
    # essa série vier de outra conta do Tiny, a busca funcionaria para uma e
    # não para a outra, e o controle teria dado licença para a conclusão errada.
    serie_investigada = ausentes.filter_map { |u| u.order.metadata.dig("nota_do_envio", "serie") }
                                .tally.max_by(&:last)&.first

    controle = Invoice.where(tenant_id: tenant.id)
                      .where.not(number: nil)
                      .where(series: serie_investigada)
                      .order(Arel.sql("RANDOM()"))
                      .first

    if controle.blank? && serie_investigada.present?
      puts "Não há nota da série #{serie_investigada} no nosso banco para usar de controle;"
      puts "caindo para qualquer série — o controle fica mais fraco."
      puts

      controle = Invoice.where(tenant_id: tenant.id)
                        .where.not(number: nil)
                        .order(Arel.sql("RANDOM()"))
                        .first
    end

    if controle.blank?
      abort "Não há nota no banco para usar de controle."
    end

    numero_controle = controle.number.to_s.sub(/\A0+/, "")

    com_serie = reader.por_numero(numero_controle, serie: controle.series)

    # E sem a série: se ela for filtro não aceito, o Tiny responde erro e o
    # nosso cliente lê erro como "nada encontrado" — vazio idêntico ao de uma
    # nota ausente.
    sem_serie = reader.por_numero(numero_controle)

    bate = ->(lista) { lista.any? { |n| n[:numero].to_s.sub(/\A0+/, "") == numero_controle } }

    puts "Controle — NF #{controle.number}/#{controle.series}, que veio do Tiny e está no nosso banco:"
    puts "  buscando com série:  #{bate.call(com_serie) ? 'ACHOU' : 'não achou'}"
    puts "  buscando sem série:  #{bate.call(sem_serie) ? 'ACHOU' : 'não achou'}"
    puts

    if !bate.call(com_serie) && !bate.call(sem_serie)
      abort "A busca por número não encontra nem uma nota que sabemos existir no Tiny.\n" \
            "O problema é a busca, não as notas. Não conclua nada da amostra abaixo."
    end

    # Se só a busca sem série funciona, é a série que atrapalha — e usar o
    # filtro que não funciona geraria 236 falsos "não existe".
    usar_serie = bate.call(com_serie)

    puts "Usando a busca #{usar_serie ? 'com' : 'sem'} série."
    puts

    pelo_pedido = 0
    pelo_numero = 0
    nao_tem = 0
    falhas = 0

    ausentes.each do |unidade|
      pedido = unidade.order

      dados = pedido.metadata["nota_do_envio"]

      # Duas perguntas, porque a primeira sozinha é ambígua: o Tiny guarda o
      # PACOTE em `numeroEcommerce` quando a venda tem mais de um item, então
      # "não conhece este pedido" cabe tanto em "não tenho a nota" quanto em
      # "tenho, sob outra chave". A busca pelo NÚMERO não tem essa dúvida.
      notas = reader.por_pedido(pedido.external_id)

      if notas.any?
        pelo_pedido += 1

        nota = notas.first

        puts format("  TEM   pedido %-20s ML diz NF %s/%s · Tiny acha pelo pedido: NF %s/%s de %s",
                    pedido.external_id, dados["numero"], dados["serie"],
                    nota[:numero], nota[:serie], nota[:data_emissao])

        sleep 0.5

        next
      end

      sleep 0.5

      numero = dados["numero"].to_s.sub(/\A0+/, "")

      achadas = reader.por_numero(numero, serie: usar_serie ? dados["serie"] : nil)

      # Só vale a nota cujo número é de fato o que pedimos: se o Tiny ignorar o
      # filtro e devolver a página inteira, aceitar a primeira seria inventar
      # uma resposta.
      certa = achadas.find { |encontrada| encontrada[:numero].to_s.sub(/\A0+/, "") == numero }

      if certa
        pelo_numero += 1

        puts format("  TEM   pedido %-20s NF %s/%s existe no Tiny (de %s, pedido lá: %s)",
                    pedido.external_id, dados["numero"], dados["serie"],
                    certa[:data_emissao], certa[:numero_ecommerce].presence || "em branco")
      else
        nao_tem += 1

        puts format("  NÃO   pedido %-20s NF %s/%s não existe no Tiny, por nenhuma das duas buscas",
                    pedido.external_id, dados["numero"], dados["serie"])
      end

      sleep 0.5
    rescue StandardError => e
      falhas += 1

      puts "  ERRO  pedido #{pedido.external_id}: #{e.class} #{e.message}"
    end

    puts
    puts "Tiny acha pelo PEDIDO:  #{pelo_pedido}   -> a importação não alcançou; conserto nosso"
    puts "Tiny acha pelo NÚMERO:  #{pelo_numero}   -> a nota existe, o elo com o pedido é que falta"
    puts "Tiny NÃO tem:           #{nao_tem}   -> emitida em outro sistema; pergunta para o cliente"
    puts "Falhas na consulta:     #{falhas}" if falhas.positive?
    puts
    puts "Nada foi gravado."
  end
end
