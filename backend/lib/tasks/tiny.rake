namespace :tiny do
  desc "Grava na nota quem intermediou a venda, lendo a NF-e do Tiny (LIMITE=200)"
  task intermediador: :environment do
    # O cliente vende no TikTok Shop, e essas notas viraram pedidos do Mercado
    # Livre — o InvoiceSync atribui à única conta ativa quando não tem outra
    # forma de saber. Elas entram na conciliação de uma conta que nunca vai
    # repassar por elas.
    #
    # Antes de consertar é preciso saber o tamanho: são oito notas ou duas
    # mil? A resposta está no grupo `intermediador` da NF-e, que só vem na
    # nota completa — uma consulta por nota.
    #
    # Escreve SÓ o intermediador na nossa nota. Não mexe em pedido, plataforma
    # nem em nada do OMIE. É retomável: pula o que já tem o campo.
    tenant = Tenant.find_by(id: ENV["TENANT"]) ||
             Tenant.order(:id).find { |t| Current.with_tenant(t) { Fiscal::Tiny::Settings.configured? } }

    abort "Nenhuma empresa com token do Tiny. Use TENANT=<id>." if tenant.blank?

    Current.tenant = tenant

    limite = (ENV["LIMITE"] || 200).to_i

    pendentes = Invoice
                  .where(tenant_id: tenant.id)
                  .where("invoices.metadata->'intermediador' IS NULL")
                  .order(issued_at: :desc)

    total_pendente = pendentes.count

    puts
    puts "Empresa: ##{tenant.id} #{tenant.name}"
    puts "Notas sem intermediador lido: #{total_pendente}"
    puts "Esta execução vai ler: #{[ limite, total_pendente ].min} (uma consulta por segundo)"
    puts

    if total_pendente.zero?
      puts "Nada a fazer. Rode `rake tiny:mapa_de_canais` para ver o resultado."

      next
    end

    # Sem isto a tarefa fica MUDA por vários minutos — uma pausa de um segundo
    # por nota, sem nenhum sinal de vida, é indistinguível de travamento. E o
    # buffer do docker segura até o que seria impresso.
    $stdout.sync = true

    client = Fiscal::Tiny::V2Client.new

    lidas = 0
    falhas = 0

    canais = Hash.new(0)

    pendentes.limit(limite).each_with_index do |nota, indice|
      sleep 1

      if (indice % 10).zero?
        puts format("  %d/%d lidas · %s", indice, [ limite, total_pendente ].min,
                    canais.sort_by { |_, n| -n }.map { |c, n| "#{c} #{n}" }.join(", ").presence || "começando")
      end

      detalhe = client.obter_nota(nota.external_id)

      if detalhe.blank?
        falhas += 1

        next
      end

      inter = detalhe["intermediador"] || {}

      canais[inter["nome"].presence || "(sem intermediador)"] += 1

      # Grava mesmo quando vem vazio: o hash presente com nome nulo é a
      # resposta "o Tiny não sabe", e é diferente de "ainda não perguntei".
      # Sem essa distinção a tarefa releria as mesmas notas para sempre.
      nota.update!(metadata: nota.metadata.merge(
        "intermediador" => { "nome" => inter["nome"], "cnpj" => inter["cnpj"] }
      ))

      lidas += 1
    rescue StandardError => e
      falhas += 1

      Rails.logger.warn "[intermediador] NF #{nota.number}: #{e.class} #{e.message}"
    end

    puts
    puts "Canais encontrados nesta leva:"
    canais.sort_by { |_, n| -n }.each { |canal, n| puts format("  %-24s %d", canal, n) }
    puts
    puts "Lidas:  #{lidas}"
    puts "Falhas: #{falhas}"
    puts "Faltam: #{total_pendente - lidas}"
    puts
    puts "Rode de novo para continuar, ou `rake tiny:mapa_de_canais` para o resumo."
  end

  desc "De quais canais vieram as vendas, e onde a atribuição está errada (SOMENTE LEITURA)"
  task mapa_de_canais: :environment do
    tenant = Tenant.find_by(id: ENV["TENANT"]) || Tenant.order(:id).first

    abort "Nenhuma empresa." if tenant.blank?

    notas = Invoice.where(tenant_id: tenant.id)

    lidas = notas.where("invoices.metadata->'intermediador' IS NOT NULL")

    puts
    puts "Empresa: ##{tenant.id} #{tenant.name}"
    puts "Notas: #{notas.count} · com intermediador lido: #{lidas.count}"
    puts

    if lidas.none?
      puts "Rode `rake tiny:intermediador` primeiro."

      next
    end

    grupos = lidas
               .group("invoices.metadata->'intermediador'->>'nome'")
               .group("invoices.metadata->'intermediador'->>'cnpj'")
               .count

    puts "Intermediador declarado na NF-e:"
    puts

    grupos.sort_by { |_, quantas| -quantas }.each do |(nome, cnpj), quantas|
      puts format("  %-24s %-22s %d nota(s)", nome || "(não informado)", cnpj || "—", quantas)

      # A que plataforma essas notas foram atribuídas no nosso banco. Quando o
      # intermediador não é o marketplace atribuído, a venda está na
      # conciliação errada.
      atribuidas = Invoice
                     .where(tenant_id: tenant.id)
                     .where("invoices.metadata->'intermediador'->>'cnpj' IS NOT DISTINCT FROM ?", cnpj)
                     .left_joins(:order)
                     .group("orders.platform")
                     .count

      puts format("    atribuídas a: %s", atribuidas.inspect)

      # Se existe dinheiro nosso para essas vendas.
      #
      # É o que separa "canal atribuído errado" de "canal que o sistema nem
      # tem de onde ler". Um se conserta mudando a atribuição; o outro precisa
      # de um conector novo, ou de assumir que aquele canal não é conciliado.
      pedidos = Invoice
                  .where(tenant_id: tenant.id)
                  .where("invoices.metadata->'intermediador'->>'cnpj' IS NOT DISTINCT FROM ?", cnpj)
                  .where.not(order_id: nil)
                  .select(:order_id)

      com_dinheiro = FinancialEntry
                       .where(tenant_id: tenant.id, order_id: pedidos)
                       .distinct
                       .count(:order_id)

      puts format("    pedidos com lançamento no extrato: %d", com_dinheiro)
      puts
    end

    puts "Contas de marketplace cadastradas: " \
         "#{tenant.platform_accounts.where(status: :active).pluck(:platform).uniq.join(', ').presence || 'nenhuma'}"
    puts
    puts "Como ler:"
    puts "  intermediador != plataforma atribuída  -> venda na conciliação errada."
    puts "  zero pedidos com lançamento            -> o sistema não lê o dinheiro"
    puts "                                            desse canal. Atribuir certo tira"
    puts "                                            a sujeira, mas não concilia."
    puts
    puts "Nada foi gravado."
  end


  desc "De qual marketplace vem cada nota, e o que o Tiny informa a respeito (SOMENTE LEITURA)"
  task origens: :environment do
    # Hoje a origem da nota só existe pelo PEDIDO, e nota sem pedido fica sem
    # nada. Pior: com mais de uma conta ativa o InvoiceSync não sabe de qual
    # marketplace é a nota e desiste — deixa de criar pedido e a corrente
    # inteira para.
    #
    # Antes de inventar regra (adivinhar pelo formato do número, por exemplo),
    # a pergunta é se o Tiny já informa isso. Esta tarefa mostra o que temos e
    # lista os NOMES dos campos que o Tiny devolve, para procurar um.
    tenant = Tenant.find_by(id: ENV["TENANT"]) ||
             Tenant.order(:id).find { |t| Current.with_tenant(t) { Fiscal::Tiny::Settings.configured? } }

    abort "Nenhuma empresa com token do Tiny. Use TENANT=<id>." if tenant.blank?

    Current.tenant = tenant

    notas = Invoice.where(tenant_id: tenant.id)

    puts
    puts "Empresa: ##{tenant.id} #{tenant.name}"
    puts "Notas: #{notas.count}"
    puts

    puts "Contas de marketplace ativas:"
    tenant.platform_accounts.where(status: :active).each do |conta|
      puts format("  ##{conta.id} %-16s %s", conta.platform, conta.external_id)
    end
    puts "  (nenhuma)" if tenant.platform_accounts.where(status: :active).none?
    puts

    # O que já dá para responder: a plataforma do pedido da nota.
    por_plataforma = notas.left_joins(:order).group("orders.platform").count

    puts "Origem conhecida hoje (pelo pedido):"
    por_plataforma.each do |plataforma, quantas|
      puts format("  %-20s %d", plataforma || "SEM PEDIDO — origem desconhecida", quantas)
    end
    puts

    # E o que o Tiny devolve. Só os NOMES dos campos: os valores trazem dado do
    # comprador, e o que interessa aqui é descobrir se existe um campo de
    # origem, não ler o conteúdo das notas.
    amostra = Fiscal::Tiny::Reader.new.notas_fiscais(
      start_date: Date.current - (ENV["DIAS"] || 30).to_i, end_date: Date.current
    ).first

    if amostra.blank?
      puts "Nenhuma nota no período para inspecionar. Tente DIAS=180."

      next
    end

    bruto = amostra[:bruto] || {}

    puts "Campos que a BUSCA do Tiny devolve:"
    puts "  #{bruto.keys.sort.join(', ')}"
    puts

    sleep 1

    detalhe = Fiscal::Tiny::V2Client.new.obter_nota(bruto["id"])

    if detalhe.present?
      puts "Campos que a NOTA COMPLETA devolve:"
      puts "  #{detalhe.keys.sort.join(', ')}"
      puts

      # `intermediador` é o grupo da NF-e criado para isto (NT 2020.006): a
      # plataforma que intermediou a venda, com CNPJ e o identificador do
      # VENDEDOR nela. Não é dado do comprador, então pode sair no log.
      #
      # A primeira versão desta tarefa procurava por "ecommerce|loja|canal" e
      # passou reto pelo campo certo.
      origem = detalhe.select do |chave, _|
        chave.to_s.match?(/intermediador|ecommerce|loja|canal|origem|marketplace|marcadores|id_venda/i)
      end

      puts "Campos que parecem indicar origem:"
      origem.each { |chave, valor| puts "  #{chave}: #{valor.inspect}" }
    end

    puts
    puts "Procure nas listas acima um campo de loja/canal. Se existir, a origem"
    puts "vem do Tiny e não precisa ser adivinhada."
    puts
    puts "Nada foi gravado."
  end


  desc "Compara o valor das notas zeradas com o que o Tiny devolve (SOMENTE LEITURA)"
  task conferir_valores: :environment do
    # O OMIE recusa título sem valor, então nota zerada nunca sobe — e o
    # repasse que a contém fica em "comparação incompleta" para sempre.
    #
    # Antes de decidir o que fazer com elas, é preciso saber de quem é o zero:
    # da nota, ou do nosso leitor. Já erramos formato de número uma vez, no CSV
    # do Mercado Livre, onde "1.150,00" virava zero em silêncio.
    tenant = Tenant.find_by(id: ENV["TENANT"]) ||
             Tenant.order(:id).find { |t| Current.with_tenant(t) { Fiscal::Tiny::Settings.configured? } }

    abort "Nenhuma empresa com token do Tiny. Use TENANT=<id>." if tenant.blank?

    Current.tenant = tenant

    zeradas = Invoice.where(tenant_id: tenant.id)
                     .where(operation_type: :sale)
                     .where("COALESCE(total_amount, 0) <= 0")
                     .order(:issued_at)

    puts
    puts "Empresa: ##{tenant.id} #{tenant.name}"
    puts "Notas sem valor no nosso banco: #{zeradas.count}"

    if zeradas.none?
      puts "Nada a conferir."
      next
    end

    reader = Fiscal::Tiny::Reader.new

    zeradas.each do |nota|
      pedido = nota.metadata["numero_ecommerce"].presence || nota.order&.external_id

      puts
      puts "NF #{nota.number}/#{nota.series} · emitida #{nota.issued_at} · pedido #{pedido || '—'}"
      puts "  nosso valor:    #{nota.total_amount.inspect}"
      puts "  situação Tiny:  #{nota.metadata['situacao_tiny'] || '—'}"

      if pedido.blank?
        puts "  (sem número de pedido: não dá para reconsultar no Tiny)"
        next
      end

      sleep 1 # o Tiny limita requisições por minuto

      encontrada = reader.por_pedido(pedido).find { |n| n[:numero].to_s == nota.number.to_s }

      if encontrada.blank?
        puts "  o Tiny não devolveu esta nota na consulta por pedido."
        next
      end

      # Só os campos de VALOR: o resto é dado do comprador e não tem por que
      # sair no log.
      bruto = encontrada[:bruto] || {}

      puts "  valor normalizado:  #{encontrada[:valor].inspect}"
      puts "  valor cru do Tiny:  #{bruto['valor'].inspect}"

      puts "  outros campos de valor (busca): #{valores_de(bruto)}"

      # A busca é uma LISTAGEM e devolve resumo. A nota completa tem os itens e
      # os totais que o cabeçalho não traz — é ela que separa "a nota não tem
      # valor" de "a listagem não calcula o valor".
      sleep 1

      detalhe = Fiscal::Tiny::V2Client.new.obter_nota(bruto["id"] || nota.external_id)

      if detalhe.blank?
        puts "  nota completa: o Tiny não devolveu."
        next
      end

      puts "  campos de valor (nota completa): #{valores_de(detalhe)}"

      itens = Array(detalhe["itens"]).map { |i| i["item"] || i }

      puts "  itens: #{itens.size}"

      itens.first(3).each do |item|
        puts format("    %-40s qtd %-6s unit %-10s total %s",
                    item["descricao"].to_s[0, 40], item["quantidade"],
                    item["valor_unitario"], item["valor_total"])
      end

      # Quanto o marketplace pagou por essa mesma venda.
      #
      # É o número que dá tamanho ao problema: a nota diz zero, mas o dinheiro
      # entrou. Vem do nosso extrato, não de chute — e serve para o contador
      # decidir o que fazer com a nota, não para eu preencher o título.
      imprimir_valor_do_marketplace(nota)
    end

    puts
    puts "Como ler:"
    puts "  valor cru preenchido e o nosso zerado -> o erro é meu, na leitura."
    puts "  busca zerada e nota completa com valor -> a listagem é que não calcula;"
    puts "                                            o conserto é meu, lendo a nota."
    puts "  as duas zeradas e sem itens com valor -> a nota é assim no Tiny mesmo."
    puts
    puts "Nada foi gravado."
  end

  # O que o marketplace movimentou para o pedido desta nota.
  #
  # `sale` é a venda bruta e `settlement` é o repasse líquido; as taxas entram
  # negativas. Interessa a venda: é ela que a nota fiscal deveria espelhar.
  def imprimir_valor_do_marketplace(nota)
    return puts "  extrato: nota sem pedido vinculado." if nota.order_id.blank?

    lancamentos = FinancialEntry.where(tenant_id: nota.tenant_id, order_id: nota.order_id)

    if lancamentos.none?
      puts "  extrato: nenhum lançamento ligado a este pedido."

      return
    end

    venda = lancamentos.where(entry_type: :sale).sum(:amount)

    puts format("  extrato do marketplace: venda R$ %.2f em %d lançamento(s) — %s",
                venda, lancamentos.count,
                lancamentos.group(:entry_type).count.map { |t, n| "#{t} #{n}" }.join(", "))
  end

  # Todos os campos que parecem valor, sem despejar a nota inteira: o resto é
  # dado do comprador e não tem por que sair num log.
  def valores_de(hash)
    hash.select { |chave, _| chave.to_s.match?(/valor|total|frete|desconto|icms|ipi/i) }
        .reject { |_, valor| valor.is_a?(Array) || valor.is_a?(Hash) }
        .inspect
  end


  desc "Importa as notas fiscais do Tiny para o nosso banco (não toca no OMIE)"
  task importar: :environment do
    # O InvoiceSync existia e ninguém o chamava — quarta peça do sistema com
    # esse problema. Sem ele a tabela `invoices` fica vazia, e é ela que
    # carrega o número da NF, que é a chave de casamento com o título do OMIE.
    #
    # Escreve SÓ no nosso banco. Nada é enviado ao OMIE aqui.
    tenant = Tenant.find_by(id: ENV["TENANT"]) ||
             Tenant.order(:id).find { |t| Current.with_tenant(t) { Fiscal::Tiny::Settings.configured? } }

    abort "Nenhuma empresa com token do Tiny. Use TENANT=<id>." if tenant.blank?

    dias = (ENV["DIAS"] || 30).to_i

    fim = Date.current
    inicio = fim - dias

    puts
    puts "Empresa: ##{tenant.id} #{tenant.name}"
    puts "Janela: #{inicio} a #{fim}"
    puts "Isto escreve apenas no banco do Willians. O OMIE não é tocado."
    puts

    resumo =
      begin
        Fiscal::Tiny::InvoiceSync
          .new(tenant: tenant)
          .call(start_date: inicio, end_date: fim)
      rescue Fiscal::Tiny::V2Client::AuthError => e
        abort "O Tiny recusou o token da empresa ##{tenant.id}: #{e.message}\n" \
              "Confira em Configurações > Tiny. O token é por empresa."
      end

    puts "Notas lidas do Tiny:      #{resumo[:lidas]}"
    puts "Pedidos criados:          #{resumo[:pedidos_criados]}"
    puts "Notas criadas:            #{resumo[:criadas]}"
    puts "Notas atualizadas:        #{resumo[:atualizadas]}"
    puts "Lançamentos vinculados:   #{resumo[:vinculados]}"
    puts

    %i[sem_referencia sem_numero sem_pedido sem_plataforma].each do |motivo|
      next if resumo[motivo].to_i.zero?

      puts format("  ignoradas por %-16s %d", motivo, resumo[motivo])
    end

    puts
    puts "Total de notas no banco agora: #{Invoice.where(tenant_id: tenant.id).count}"
  end


  desc "Testa a conexão com o Tiny e mede o elo pedido -> NF (SOMENTE LEITURA)"
  task check: :environment do
    # As chaves do Tiny e do OMIE ficam por EMPRESA (tela de Configurações), e
    # rake roda sem `Current.tenant`. Sem escolher a empresa, `configured?`
    # olhava só o ambiente e concluía que nada estava configurado — o mesmo
    # falso negativo que a `omie:titulos` deu.
    tenant = Tenant.find_by(id: ENV["TENANT"]) ||
             Tenant.order(:id).find { |t| Current.with_tenant(t) { Fiscal::Tiny::Settings.configured? } }

    if tenant.blank?
      abort "Nenhuma empresa com token do Tiny. No Tiny: instale a extensão 'Token API' em " \
            "Início > Extensões da Olist, depois Configurações > aba E-commerce > Token API. " \
            "Cole o token em Configurações > Tiny. Use TENANT=<id> para escolher a empresa."
    end

    Current.tenant = tenant

    unless Fiscal::Tiny::Settings.configured?
      abort "A empresa ##{tenant.id} #{tenant.name} não tem token do Tiny. Use TENANT=<id>."
    end

    dias = (ENV["DIAS"] || 30).to_i

    fim = Date.current
    inicio = fim - dias

    puts "Empresa: ##{tenant.id} #{tenant.name}"
    puts "API do Tiny: #{Fiscal::Tiny::Settings.version}"
    puts "Janela: #{inicio} a #{fim}"
    puts

    notas = Fiscal::Tiny::Reader.new.notas_fiscais(start_date: inicio, end_date: fim)

    if notas.empty?
      puts "Nenhuma nota fiscal no período. Tente DIAS=180."
      next
    end

    puts "Notas encontradas: #{notas.size}"
    puts

    com_ecommerce = notas.count { |n| n[:numero_ecommerce].present? }
    com_chave = notas.count { |n| n[:chave_acesso].present? }
    com_numero = notas.count { |n| n[:numero].present? }

    puts "Preenchimento dos campos que a conciliação usa:"
    puts format("  %-22s %4d/%-4d  %s", "numero_ecommerce", com_ecommerce, notas.size,
                com_ecommerce == notas.size ? "<-- o elo com o pedido existe" : "")
    puts format("  %-22s %4d/%-4d", "numero (da NF)", com_numero, notas.size)
    puts format("  %-22s %4d/%-4d", "chave_acesso", com_chave, notas.size)
    puts

    puts "Amostra:"
    notas.first(5).each do |n|
      puts format("  pedido %-24s NF %-8s serie %-4s R$ %-10s %s",
                  n[:numero_ecommerce].inspect, n[:numero], n[:serie], n[:valor], n[:data_emissao])
    end
    puts

    # O cliente lança o título contra o COMPRADOR, não contra o marketplace.
    # Então o cadastro do comprador precisa existir no OMIE — e a primeira
    # pergunta é se a busca de notas do Tiny já traz o que isso exige.
    puts "Dados do comprador (o título a receber vai contra ele):"

    %i[cliente_nome cliente_documento].each do |campo|
      preenchidos = notas.count { |n| n[campo].present? }

      puts format("  %-22s %d/%d", campo, preenchidos, notas.size)
    end

    exemplo = notas.find { |n| n[:cliente_nome].present? }

    if exemplo
      puts format("  exemplo: %s / %s", exemplo[:cliente_nome], exemplo[:cliente_documento])
    else
      puts "  A busca de notas do Tiny NÃO traz o comprador — seria preciso ler nota a nota."
    end

    compradores = notas.filter_map { |n| n[:cliente_documento] }.uniq.size

    puts "  compradores distintos nesta janela: #{compradores}"
    puts

    # A prova real: o número da NF do Tiny bate com o título no Omie?
    if Omie::Client.configured?
      puts "Conferindo contra os títulos do Omie..."

      numeros = notas.filter_map { |n| n[:numero] }.uniq

      titulos = Omie::Client.new.request(
        "financas/contareceber/", "ListarContasReceber",
        pagina: 1, registros_por_pagina: 200, filtrar_apenas_titulos_em_aberto: "S"
      )["conta_receber_cadastro"] || []

      docs = titulos.filter_map { |t| t["numero_documento"].to_s.sub(/\A0+/, "").presence }.to_set

      casaram = numeros.count { |n| docs.include?(n.to_s.sub(/\A0+/, "")) }

      puts "  números de NF do Tiny: #{numeros.size}"
      puts "  títulos em aberto lidos do Omie: #{docs.size}"
      puts "  bateram: #{casaram}"
      puts

      if casaram.positive?
        puts "  A CORRENTE FECHA: pedido -> NF (Tiny) -> título (Omie)."
      else
        puts "  Nenhum casou nesta amostra. Pode ser janela diferente entre os dois"
        puts "  sistemas — tente DIAS maior antes de concluir que não bate."
      end
    else
      puts "(Omie não configurado; pulei a conferência cruzada.)"
    end

    puts
    puts "Nenhum dado foi gravado."
  rescue Fiscal::Tiny::V2Client::AuthError => e
    abort "Token do Tiny recusado: #{e.message}"
  rescue StandardError => e
    abort "#{e.class}: #{e.message}"
  end
end
