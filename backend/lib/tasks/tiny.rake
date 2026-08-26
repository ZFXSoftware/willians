namespace :tiny do
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

    resumo = Fiscal::Tiny::InvoiceSync
               .new(tenant: tenant)
               .call(start_date: inicio, end_date: fim)

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
