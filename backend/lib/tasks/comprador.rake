namespace :ml do
  desc "Acha a nota de uma venda pelo COMPRADOR, e mostra sob que chave ela está (SOMENTE LEITURA)"
  task comprador: :environment do
    # Valor e data não identificam nada: a loja vende o mesmo modelo por
    # R$ 184,65 em cinco canais, e qualquer venda casa com dezenas de notas.
    # A tentativa anterior devolveu coincidência pura.
    #
    # O comprador identifica. Nossas notas guardam `comprador_documento`, e o
    # Mercado Livre informa o documento do comprador ao VENDEDOR. Se a nota da
    # venda existir com outra chave, é assim que se acha — e o
    # `numero_ecommerce` dela é a resposta que falta.
    #
    # O documento NÃO é impresso: só os três últimos dígitos, o suficiente
    # para conferir que é a mesma pessoa.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    conta = tenant.platform_accounts.where(status: :active, platform: "mercado_livre").first

    abort "Esta empresa não tem conta ativa do Mercado Livre." if conta.blank?

    quantos = (ENV["QUANTOS"] || 8).to_i

    cliente = Marketplace::MercadoLivre::OrdersClient.new(
      access_token: Marketplace::Credentials::TokenProvider.new(platform_account: conta).access_token,
      seller_id: conta.external_id
    )

    sem_nota = ReceivableUnit
                 .where(tenant_id: tenant.id, invoice_id: nil)
                 .where.not(order_id: nil)
                 .includes(:order)
                 .order(Arel.sql("RANDOM()"))
                 .limit(quantos)

    puts "Conferindo #{quantos} venda(s) pelo comprador."
    puts

    sem_documento = 0
    achadas = 0
    nenhuma = 0
    chaves = Hash.new(0)

    sem_nota.each do |unidade|
      referencia = unidade.order&.external_id

      next if referencia.blank?

      sleep 1

      bruto = cliente.order_raw(referencia)

      documento = documento_do_comprador(bruto)

      # O pedido não traz mais o documento; o endpoint de dados fiscais traz.
      if documento.blank?
        sleep 1

        documento = documento_do_comprador(cliente.billing_info(referencia)) rescue nil
      end

      if documento.blank?
        sem_documento += 1

        # Sem isto a conclusão seria "o ML não devolve", quando pode ser que
        # devolva num campo que a varredura não reconhece. Os nomes dos campos
        # não são dado sensível.
        puts "  #{referencia}: sem documento. Campos recebidos: #{bruto.keys.sort.join(', ')}"

        comprador = bruto["buyer"]

        puts "    dentro de buyer: #{comprador.keys.sort.join(', ')}" if comprador.is_a?(Hash)

        next
      end

      janela = (unidade.expected_on || Date.current) - 60..(unidade.expected_on || Date.current)

      # CPF sozinho não basta: comprador que volta tem várias notas, e uma
      # delas veio com a chave de OUTRO pedido dele. Com o valor junto, o
      # falso positivo some.
      valor = unidade.gross_amount.to_d

      notas = Invoice
                .where(tenant_id: tenant.id, operation_type: :sale)
                .where(issued_at: janela)
                .where("regexp_replace(invoices.metadata->>'comprador_documento', '\\D', '', 'g') = ?", documento)
                .where(total_amount: (valor - 30)..(valor + 30))
                .limit(3)

      if notas.none?
        nenhuma += 1

        puts format("  %s: comprador ...%s -> nenhuma nota nossa para ele", referencia, documento.last(3))

        next
      end

      achadas += 1

      notas.each do |nota|
        chave = nota.metadata.to_h["numero_ecommerce"].to_s

        chaves[chave == referencia ? "igual ao pedido" : classificar(chave)] += 1

        puts format("  %s: comprador ...%s -> NF %s sob a chave %s  [%s]",
                    referencia, documento.last(3), nota.number, chave.presence || "vazia",
                    classificar(chave))
      end
    rescue StandardError => e
      puts "  #{referencia}: #{e.class} #{e.message}"
    end

    puts
    puts "Com nota encontrada pelo comprador: #{achadas}"
    puts "Sem nota nenhuma para o comprador:  #{nenhuma}"
    puts "Sem documento na resposta do ML:    #{sem_documento}"
    puts

    if chaves.any?
      puts "Sob que chave a nota estava:"
      chaves.sort_by { |_, quantas| -quantas }.each { |chave, quantas| puts format("  %-40s %d", chave, quantas) }
    end

    puts
    puts "Nada foi gravado."
  end

  # O documento do comprador aparece em lugares diferentes conforme o tipo de
  # venda. Procurar em todos evita concluir "não tem" quando é só outro campo.
  # Varredura em profundidade, e não caminhos fixos.
  #
  # O documento muda de lugar conforme o tipo de venda e a versão da resposta,
  # e procurar em três caminhos conhecidos já devolveu "não tem" oito vezes
  # seguidas para pedidos que certamente têm comprador.
  def documento_do_comprador(payload)
    encontrado = nil

    procurar = lambda do |no|
      return if encontrado

      case no
      when Hash
        no.each do |chave, valor|
          if chave.to_s.match?(/doc_number|\Anumber\z|cpf|cnpj|identification_number/i) &&
             valor.to_s.gsub(/\D/, "").length.in?([ 11, 14 ])
            encontrado = valor.to_s.gsub(/\D/, "")

            return
          end

          procurar.call(valor)
        end
      when Array
        no.each { |item| procurar.call(item) }
      end
    end

    procurar.call(payload)

    encontrado
  end

  def classificar(chave)
    case chave
    when "" then "vazia"
    # Pacotes e pedidos vivem em FAIXAS diferentes: os pacotes observados vão
    # de 20000141 a 20000147, os pedidos de 20000172 para cima. A primeira
    # versão só reconhecia 20000146 e rotulou quatro pacotes como "outro
    # pedido" — o classificador mentindo é pior que classificador nenhum.
    when /\A2000014\d{9}\z/ then "PACOTE do Mercado Livre"
    when /\A2000\d{12}\z/ then "outro pedido do Mercado Livre"
    when /\A\d{17,19}\z/ then "18 dígitos (TikTok)"
    when /\A\d{3}-\d{7}-\d{7}\z/ then "Amazon"
    when /\ALU-/ then "Magalu"
    else "outro formato"
    end
  end
end
