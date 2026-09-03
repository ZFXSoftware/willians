namespace :conciliacao do
  desc "Procura, no nosso banco, a nota das vendas pagas sem pacote (SOMENTE LEITURA)"
  task nota_perdida: :environment do
    # Sobrou o balde sem explicação: vendas REAIS e pagas no Mercado Livre, sem
    # pacote, e o Tiny não tem nota com aquele número de pedido. São ~40% das
    # 543.
    #
    # Antes de perguntar de novo a quem quer que seja: se a nota existe e está
    # gravada com OUTRA chave, ela está no nosso banco e dá para achá-la pelo
    # valor e pela data. O que ela trouxer em `numero_ecommerce` diz qual chave
    # o Tiny usou — e é isso que falta para fechar o elo.
    #
    # Nenhuma chamada externa: são 3943 notas no banco.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    quantos = (ENV["QUANTOS"] || 15).to_i

    # Tolerância no valor porque a NF e a venda no marketplace não são a mesma
    # grandeza: vimos diferenças de R$ 4,00 e de frete inteiro.
    tolerancia = BigDecimal(ENV["TOLERANCIA"] || "5")

    # Só as que já sabemos não ter pacote seria o ideal, mas isso exige o ML.
    # Aqui vale qualquer venda paga sem nota: as com pacote vão aparecer com a
    # nota do pacote, e isso também é informação.
    sem_nota = ReceivableUnit
                 .where(tenant_id: tenant.id, invoice_id: nil)
                 .where.not(order_id: nil)
                 .includes(:order)
                 .order(Arel.sql("RANDOM()"))
                 .limit(quantos)

    puts "Procurando a nota de #{quantos} venda(s) por VALOR e DATA."
    puts "Tolerância de R$ #{tolerancia.to_f} no valor."
    puts

    achadas = 0
    nenhuma = 0
    chaves = Hash.new(0)

    sem_nota.each do |unidade|
      pedido = unidade.order

      valor = unidade.gross_amount.to_d

      janela = (unidade.expected_on || Date.current) - 45..(unidade.expected_on || Date.current)

      candidatas = Invoice
                     .where(tenant_id: tenant.id, operation_type: :sale)
                     .where(issued_at: janela)
                     .where(total_amount: (valor - tolerancia)..(valor + tolerancia))
                     .limit(3)

      if candidatas.none?
        nenhuma += 1

        puts format("  %-22s R$ %8.2f -> nenhuma nota com esse valor na janela", pedido&.external_id, valor)

        next
      end

      achadas += 1

      candidatas.each do |nota|
        referencia = nota.metadata.to_h["numero_ecommerce"].to_s

        # O formato da chave é a resposta que interessa: se o Tiny gravou algo
        # que não é o id do pedido nem o do pacote, é uma terceira chave e
        # precisamos saber qual.
        chaves[formato_da(referencia, pedido&.external_id)] += 1

        puts format("  %-22s R$ %8.2f -> NF %s (numero_ecommerce %s) de %s",
                    pedido&.external_id, valor, nota.number, referencia.presence || "vazio",
                    nota.issued_at&.to_date)
      end
    end

    puts
    puts "Vendas com alguma nota compatível: #{achadas}"
    puts "Vendas sem nenhuma nota compatível: #{nenhuma}"
    puts

    if chaves.any?
      puts "Que chave o Tiny gravou nessas notas:"
      chaves.sort_by { |_, quantas| -quantas }.each { |formato, quantas| puts format("  %-34s %d", formato, quantas) }
    end

    puts
    puts "Coincidência de valor NÃO é prova: dois pedidos do mesmo produto têm o"
    puts "mesmo valor. O que vale é o PADRÃO da chave — se todas trouxerem o"
    puts "mesmo formato estranho, achamos a terceira chave."
    puts
    puts "Nada foi gravado."
  end

  def formato_da(referencia, pedido)
    return "(vazio)" if referencia.blank?

    return "igual ao pedido" if referencia == pedido

    case referencia
    when /\A2000\d{12}\z/ then "id do Mercado Livre (outro pedido/pacote)"
    when /\A\d{17,19}\z/  then "18 dígitos (TikTok?)"
    when /\A\d{3}-\d{7}-\d{7}\z/ then "Amazon"
    when /\ALU-/ then "Magalu"
    when /\A\d{6}[A-Z0-9]+\z/ then "Shopee"
    else "outro formato"
    end
  end
end
