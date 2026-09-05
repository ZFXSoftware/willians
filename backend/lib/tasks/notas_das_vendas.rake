namespace :conciliacao do
  desc "O que o marketplace respondeu sobre a nota de cada venda (SOMENTE LEITURA)"
  task notas_das_vendas: :environment do
    # O ciclo já perguntou ao marketplace sobre todas as vendas sem nota, e a
    # resposta ficou gravada em cada pedido. Faltava algo que a mostrasse — o
    # mesmo defeito da observação da conciliação, que existia só no banco.
    #
    # Este é o relatório que vai para a conversa com o cliente: três listas,
    # com número e nome, e cada uma com uma providência diferente.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    perguntados = Order
                    .where(tenant_id: tenant.id)
                    .where("orders.metadata->'nota_do_envio' IS NOT NULL")

    puts "Pedidos perguntados ao marketplace: #{perguntados.count}"
    puts

    if perguntados.none?
      puts "Nenhum ainda. O ciclo pergunta em lotes; rode `rake ml:nota_do_envio` para adiantar."

      next
    end

    sem_nota = []
    com_nota = []

    perguntados.find_each do |pedido|
      dados = pedido.metadata["nota_do_envio"]

      if dados.is_a?(String)
        sem_nota << pedido

        next
      end

      com_nota << [ pedido, dados ]
    end

    # Das que o marketplace conhece, quais já estão ligadas e quais não.
    ligadas = 0
    faltando = []

    com_nota.each do |pedido, dados|
      tem = ReceivableUnit.where(tenant_id: tenant.id, order_id: pedido.id).where.not(invoice_id: nil).exists?

      tem ? ligadas += 1 : faltando << [ pedido, dados ]
    end

    puts "O marketplace TEM a nota:        #{com_nota.size}"
    puts "  já ligada à venda:             #{ligadas}"
    puts "  a nota não está no nosso banco: #{faltando.size}"
    puts
    puts "O marketplace NÃO tem nota:      #{sem_nota.size}"
    puts

    if faltando.any?
      puts "Notas que existem e nós não temos (número/série):"

      faltando.first(15).each do |pedido, dados|
        puts format("  pedido %-20s NF %s/%s de %s  R$ %s",
                    pedido.external_id, dados["numero"], dados["serie"], dados["data"], dados["valor"])
      end

      puts "  ... (#{faltando.size - 15} outras)" if faltando.size > 15

      puts
      puts "  Providência: importar essas do Tiny, ou descobrir qual sistema as emitiu."
      puts
    end

    if sem_nota.any?
      puts "Vendas sem NF-e registrada no marketplace:"

      sem_nota.first(10).each { |pedido| puts "  #{pedido.external_id}" }

      puts "  ... (#{sem_nota.size - 10} outras)" if sem_nota.size > 10

      puts
      puts "  O marketplace exige nota para despachar, e não tem registro destas."
      puts "  Providência: perguntar ao cliente. Não é problema de software."
      puts
    end

    puts "Nada foi gravado."
  end
end
