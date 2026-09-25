namespace :ml do
  desc "Por que a fila de notas do Mercado Livre está vazia? Funil etapa por etapa (SOMENTE LEITURA)"
  task fila_vazia: :environment do
    # `chaves_que_faltam` diz que 10 vendas têm a chave da NF-e e a nota não está
    # no nosso banco. A fila de importação diz 0. Uma das duas está errada, e
    # dizer qual por leitura de código já me falhou duas vezes hoje.
    #
    # Então: o funil. Cada etapa da consulta, com o número que sobra depois
    # dela. A etapa em que 10 vira 0 é a resposta, e ela aparece sem eu precisar
    # adivinhar qual é.
    #
    # Primeiro de tudo, qual CÓDIGO está rodando: em produção o backend é assado
    # na imagem, então um `git pull` sem `subir` deixa o container na versão
    # anterior — e aí o zero não fala sobre os dados, fala sobre o deploy.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    fonte = Marketplace::MercadoLivre::NotaFiscal.instance_method(:pendentes).source_location&.first

    codigo = fonte && File.exist?(fonte) ? File.read(fonte) : ""

    puts "Código que está rodando neste container:"
    if codigo.include?("length(regexp_replace")
      puts "  compara por CHAVE e por número+SÉRIE (corrigido)"
    elsif codigo.include?("NOT EXISTS")
      puts "  compara só pelo NÚMERO (versão ANTIGA — falta `subir`)"
    else
      puts "  não consegui ler #{fonte.inspect}"
    end
    puts

    # As contas, porque a tarefa escolhe com `find_by` — sem ordenação. Se houver
    # mais de uma ativa, ela pega uma qualquer, e os recebíveis da outra ficam
    # invisíveis com a fila parecendo vazia.
    contas = PlatformAccount.where(tenant_id: tenant.id, platform: "mercado_livre").order(:id)

    escolhida = PlatformAccount.find_by(tenant_id: tenant.id, platform: "mercado_livre", status: "active")

    puts "Contas do Mercado Livre nesta empresa:"
    contas.each do |conta|
      marca = conta.id == escolhida&.id ? " <- a que o find_by escolhe" : ""
      puts format("  #%-4d status %-10s externo %s%s",
                  conta.id, conta.status, conta.external_id.presence || "(vazio)", marca)
    end
    puts

    resumo_serie = Hash.new(0)

    # `issued` sem vínculo é defeito nosso; `cancelled` é o sistema recusando
    # uma nota que não vale, e aí a providência é do cliente.
    glosa = lambda do |estado|
      case estado
      when "cancelled" then "  <- correto: cancelada não é a nota da venda"
      when "issued"    then "  <- DEFEITO NOSSO: devia estar ligada"
      else ""
      end
    end

    base = ReceivableUnit.where(tenant_id: tenant.id, invoice_id: nil)

    com_marca = base.joins(:order).where("jsonb_typeof(orders.metadata->'nota_do_envio') = 'object'")

    com_chave = com_marca.where(
      "length(regexp_replace(COALESCE(orders.metadata->'nota_do_envio'->>'chave',''), '\\D', '', 'g')) = 44"
    )

    puts "Funil, em TODAS as contas:"
    puts format("  recebíveis sem nota:                 %d", base.count)
    puts format("  ... com a marca nota_do_envio:       %d", com_marca.count)
    puts format("  ... com chave de 44 dígitos:         %d", com_chave.count)
    puts

    puts "  desses, por conta:"
    com_chave.group(:platform_account_id).count.sort.each do |conta_id, quantos|
      marca = conta_id == escolhida&.id ? " <- a escolhida" : " <- INVISÍVEL para a tarefa"
      puts format("    conta #%-4d %4d%s", conta_id, quantos, marca)
    end
    puts

    # Agora o filtro que decide: a nota já está aqui? Separado em dois motivos,
    # porque "achou pela chave" e "achou por número+série" pedem providências
    # diferentes — o primeiro é vínculo a fazer, o segundo é coincidência de
    # numeração entre séries.
    # O STATUS da nota encontrada, e não só a existência dela.
    #
    # Minha sonda anterior perguntou "a nota está no banco?" e eu li a resposta
    # como "há nota para ligar". `ReligarPeloEnvio` pula cancelada de propósito,
    # então nota encontrada e cancelada é sistema CERTO, não pendência. Duas
    # perguntas diferentes que eu tratei como uma.
    pela_chave = Hash.new(0)
    pelo_numero = Hash.new(0)
    ausentes = []

    com_chave.includes(:order).find_each do |unidade|
      dados = unidade.order.metadata["nota_do_envio"]

      chave = dados["chave"].to_s.gsub(/\D/, "")

      numero = dados["numero"].to_s.sub(/\A0+/, "")

      serie = dados["serie"].to_s.sub(/\A0+/, "")

      achada_por_chave = Invoice.where(tenant_id: tenant.id)
                                .where("regexp_replace(COALESCE(access_key,''), '\\D', '', 'g') = ?", chave)
                                .first

      achada_por_numero = if numero.present?
        Invoice.where(tenant_id: tenant.id)
               .where("regexp_replace(COALESCE(number,''), '\\A0+', '') = ?", numero)
               .where("regexp_replace(COALESCE(series,''), '\\A0+', '') = ?", serie)
               .first
      end

      if achada_por_chave
        pela_chave[achada_por_chave.status.to_s] += 1
      elsif achada_por_numero
        pelo_numero[achada_por_numero.status.to_s] += 1

        # A série GRAVADA, porque `ReligarPeloEnvio` compara a string crua
        # contra [serie, serie sem zeros, nil] — se o banco guardar "002" ele
        # não acha, e a minha consulta aqui normaliza os dois lados e acha.
        if achada_por_numero.series.to_s != serie && achada_por_numero.series.present?
          resumo_serie[achada_por_numero.series.to_s] += 1
        end
      else
        ausentes << [ unidade, dados ]
      end
    end

    puts "  a nota já está no nosso banco? (com o STATUS dela)"
    puts format("    sim, pela CHAVE:               %4d", pela_chave.values.sum)
    pela_chave.sort.each { |estado, q| puts format("        %-12s %4d%s", estado, q, glosa.call(estado)) }
    puts format("    sim, por NÚMERO+SÉRIE:         %4d", pelo_numero.values.sum)
    pelo_numero.sort.each { |estado, q| puts format("        %-12s %4d%s", estado, q, glosa.call(estado)) }
    puts format("    NÃO está:                      %4d  <- é isto que a fila devia trazer", ausentes.size)
    puts

    if resumo_serie.any?
      puts "  ATENÇÃO: série gravada diferente da que o envio informou —"
      puts "  o religamento compara a string crua e não acharia estas:"
      resumo_serie.sort.each { |serie_gravada, q| puts format("    série %-8s %4d", serie_gravada, q) }
      puts
    end

    if ausentes.any?
      puts "  as que faltam (até 12):"
      ausentes.first(12).each do |unidade, dados|
        puts format("    conta #%-4d NF %-8s série %-4s chave ...%s  R$ %.2f",
                    unidade.platform_account_id, dados["numero"], dados["serie"],
                    dados["chave"].to_s.gsub(/\D/, "").last(6), unidade.gross_amount.to_d)
      end
      puts
    end

    puts "Como ler:"
    puts "  se `NÃO está` for maior que zero e o número por conta mostrar"
    puts "     INVISÍVEL, o problema é o find_by escolhendo a conta errada."
    puts "  se `sim, pela CHAVE` levar tudo, a nota está aqui e falta o VÍNCULO:"
    puts "     é trabalho do religamento, não da importação."
    puts
    puts "Nada foi gravado."
  end
end
