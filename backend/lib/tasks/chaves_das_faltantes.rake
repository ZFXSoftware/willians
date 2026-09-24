namespace :conciliacao do
  desc "Lista as chaves das NF-e que faltam no nosso banco (SOMENTE LEITURA; SO_CHAVES=1 lista só as chaves)"
  task chaves_das_faltantes: :environment do
    # Para levar ao cliente, ao contador, ou para consultar em portal.
    #
    # A chave é a identidade do documento: 44 dígitos com CNPJ do emissor,
    # série, número e competência. Verificado nesta base em 261 de 261 casos —
    # o número dentro da chave bate com o que o marketplace informou.
    #
    # Não imprime nada do comprador: só o que identifica o DOCUMENTO.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    faltantes = []

    Order
      .where(tenant_id: tenant.id)
      .where("jsonb_typeof(orders.metadata->'nota_do_envio') = 'object'")
      .find_each do |pedido|
        dados = pedido.metadata["nota_do_envio"]

        chave = dados["chave"].to_s.gsub(/\D/, "")

        next if chave.length != 44

        numero = dados["numero"].to_s.sub(/\A0+/, "")

        next if numero.blank?

        # Só o que NÃO está no nosso banco: é essa a lista pedida.
        next if Invoice.where(tenant_id: tenant.id)
                       .where("regexp_replace(COALESCE(number,''), '\\A0+', '') = ?", numero)
                       .exists?

        faltantes << {
          chave: chave,
          numero: dados["numero"],
          serie: dados["serie"],
          data: dados["data"].to_s.first(10),
          valor: dados["valor"],
          pedido: pedido.external_id
        }
      end

    if faltantes.none?
      puts "Nenhuma. Todas as notas que o marketplace informou já estão no banco."

      next
    end

    # Ordem por número: é assim que alguém confere uma lista de notas.
    faltantes.sort_by! { |n| [ n[:serie].to_s, n[:numero].to_s.sub(/\A0+/, "").to_i ] }

    # Só as chaves, uma por linha: para colar em portal ou mandar por e-mail.
    if ENV["SO_CHAVES"] == "1"
      faltantes.each { |n| puts n[:chave] }

      next
    end

    puts "#{faltantes.size} nota(s) que o marketplace conhece e o nosso banco não tem."
    puts

    por_serie = faltantes.group_by { |n| n[:serie] }

    por_serie.each do |serie, lista|
      numeros = lista.map { |n| n[:numero].to_s.sub(/\A0+/, "").to_i }

      puts format("  série %-4s %4d nota(s) · de %s a %s", serie, lista.size, numeros.min, numeros.max)
    end

    puts
    puts format("  valor somado: R$ %.2f", faltantes.sum { |n| n[:valor].to_d })
    puts

    puts format("%-46s %-9s %-4s %-12s %12s  %s", "chave de acesso", "número", "sér", "emitida", "valor", "pedido")

    faltantes.each do |n|
      puts format("%-46s %-9s %-4s %-12s %12.2f  %s",
                  n[:chave], n[:numero], n[:serie], n[:data], n[:valor].to_d, n[:pedido])
    end

    puts
    puts "Para uma lista só de chaves, colável: acrescente SO_CHAVES=1"
    puts
    puts "Nada foi gravado."
  end
end
