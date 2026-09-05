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

    tem = 0
    nao_tem = 0
    falhas = 0

    ausentes.each do |unidade|
      pedido = unidade.order

      dados = pedido.metadata["nota_do_envio"]

      notas = reader.por_pedido(pedido.external_id)


      if notas.any?
        tem += 1

        notas.first(2).each do |nota|
          puts format("  TEM   pedido %-20s ML diz NF %s/%s · Tiny responde NF %s/%s de %s",
                      pedido.external_id, dados["numero"], dados["serie"],
                      nota[:numero], nota[:serie], nota[:data_emissao])
        end
      else
        nao_tem += 1

        puts format("  NÃO   pedido %-20s ML diz NF %s/%s · Tiny não conhece este pedido",
                    pedido.external_id, dados["numero"], dados["serie"])
      end

      sleep 0.5
    rescue StandardError => e
      falhas += 1

      puts "  ERRO  pedido #{pedido.external_id}: #{e.class} #{e.message}"
    end

    puts
    puts "O Tiny TEM a nota:      #{tem}   -> a importação é que não alcançou; conserto nosso"
    puts "O Tiny NÃO tem:         #{nao_tem}   -> emitida em outro sistema; pergunta para o cliente"
    puts "Falhas na consulta:     #{falhas}" if falhas.positive?
    puts
    puts "Nada foi gravado."
  end
end
