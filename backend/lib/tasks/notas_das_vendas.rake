namespace :conciliacao do
  desc "O que o marketplace respondeu sobre a nota de cada venda (SOMENTE LEITURA)"
  task notas_das_vendas: :environment do
    # O ciclo já perguntou ao marketplace sobre todas as vendas sem nota, e a
    # resposta ficou gravada em cada pedido. Faltava algo que a mostrasse.
    #
    # E a marca sozinha NÃO diz se a nota está no nosso banco: ela guarda os
    # dados que o marketplace devolveu, iguais nos dois casos. Por isso este
    # relatório PROCURA cada nota, em três regras cada vez mais frouxas — assim
    # "não temos essa nota" se separa de "temos e o pareamento não encontra",
    # que é defeito nosso e mandaria o cliente procurar no lugar errado.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    perguntados = Order
                    .where(tenant_id: tenant.id)
                    .where("orders.metadata->'nota_do_envio' IS NOT NULL")

    puts "Pedidos perguntados ao marketplace: #{perguntados.count}"
    puts

    next puts("Nenhum ainda. Rode `rake ml:nota_do_envio` para adiantar.") if perguntados.none?

    def limpo(valor) = valor.to_s.gsub(/\D/, "")

    def sem_zeros(valor) = valor.to_s.sub(/\A0+/, "")

    sem_nota = []
    achados = { chave: [], numero_e_serie: [], so_numero: [] }
    ausentes = []
    ligados = 0

    perguntados.find_each do |pedido|
      dados = pedido.metadata["nota_do_envio"]

      next sem_nota << pedido if dados.is_a?(String)

      ligado = ReceivableUnit.where(tenant_id: tenant.id, order_id: pedido.id)
                             .where.not(invoice_id: nil).exists?

      ligados += 1 if ligado

      notas = Invoice.where(tenant_id: tenant.id)

      numero = sem_zeros(dados["numero"])

      # 1. Chave de acesso: identidade, casamento exato.
      por_chave = notas.where("regexp_replace(COALESCE(access_key,''), '\\D', '', 'g') = ?",
                              limpo(dados["chave"])).first

      next achados[:chave] << [ pedido, dados, por_chave, ligado ] if por_chave

      # 2. Número + série, a regra que o religamento usa hoje.
      por_numero = notas.where("regexp_replace(COALESCE(number,''), '\\A0+', '') = ?", numero)

      com_serie = por_numero.where(series: [ dados["serie"].to_s, sem_zeros(dados["serie"]), nil ]).first

      next achados[:numero_e_serie] << [ pedido, dados, com_serie, ligado ] if com_serie

      # 3. Só o número. Se aparecer aqui, a nota EXISTE e foi a série que
      #    separou — defeito nosso, não ausência.
      solta = por_numero.first

      next achados[:so_numero] << [ pedido, dados, solta, ligado ] if solta

      ausentes << [ pedido, dados ]
    end

    com_nota = achados.values.sum(&:size) + ausentes.size

    puts "O marketplace TEM a nota:            #{com_nota}"
    puts "  ligada à venda hoje:               #{ligados}"
    puts
    puts "  procurando no nosso banco:"
    puts "    achada pela CHAVE:               #{achados[:chave].size}"
    puts "    achada por NÚMERO + SÉRIE:       #{achados[:numero_e_serie].size}"
    puts "    achada só pelo NÚMERO:           #{achados[:so_numero].size}   <- a série é que não bate"
    puts "    não está no nosso banco:         #{ausentes.size}"
    puts
    puts "O marketplace NÃO tem nota:          #{sem_nota.size}"
    puts

    soltas = achados.values.flatten(1).reject(&:last)

    # Nota cancelada solta é o comportamento CERTO: `soltar_canceladas!` a
    # solta a cada ciclo de propósito, porque ela não é a nota da venda. Contar
    # isso como falha de vínculo mandaria consertar o que está correto.
    canceladas, falhas = soltas.partition { |_, _, nota, _| nota.status.to_s == "cancelled" }

    if canceladas.any?
      puts "Achadas, porém CANCELADAS (#{canceladas.size}) — soltas de propósito:"
      puts "  Providência: o cliente precisa emitir a nota que substituiu cada uma."
      puts
    end

    if falhas.any?
      puts "Achadas no nosso banco e NÃO ligadas (#{falhas.size}) — o vínculo é que falhou:"

      falhas.first(5).each do |pedido, dados, nota, _|
        puts format("  pedido %-20s ML diz NF %s/%s · nosso banco tem NF %s/%s (id %s, chave %s)",
                    pedido.external_id, dados["numero"], dados["serie"],
                    nota.number, nota.series, nota.id,
                    nota.access_key.presence ? "sim" : "VAZIA")
      end

      puts
      puts "  Providência: `rake ml:religar_pelo_envio` — é pareamento local, sem API."
      puts
    end

    if ausentes.any?
      puts "Notas que o marketplace tem e nós não (#{ausentes.size}):"

      ausentes.first(10).each do |pedido, dados|
        puts format("  pedido %-20s NF %s/%s de %s  R$ %s",
                    pedido.external_id, dados["numero"], dados["serie"],
                    dados["data"].to_s.first(10), dados["valor"])
      end

      puts "  ... (#{ausentes.size - 10} outras)" if ausentes.size > 10

      puts

      # A faixa diz se é buraco na importação ou nota de outro sistema: número
      # DENTRO de uma faixa que temos é lacuna nossa; fora dela, é outra origem.
      # Onde os números caem decide a providência: ABAIXO do que importamos é
      # janela de importação curta, e o conserto é nosso — buscar mais para
      # trás no Tiny. DENTRO da faixa é nota que o Tiny não tem, e aí a
      # pergunta é do cliente: qual sistema emitiu.
      faixas = Invoice.where(tenant_id: tenant.id)
                      .group(:series)
                      .pluck(Arel.sql("series, MIN(NULLIF(regexp_replace(COALESCE(number,''),'\\D','','g'),'')::bigint), MAX(NULLIF(regexp_replace(COALESCE(number,''),'\\D','','g'),'')::bigint)"))
                      .to_h { |serie, menor, maior| [ serie.to_s, [ menor, maior ] ] }

      posicao = Hash.new(0)

      ausentes.each do |_, dados|
        faixa = faixas[dados["serie"].to_s]

        numero = sem_zeros(dados["numero"]).to_i

        posicao[faixa.nil? ? :serie_desconhecida : numero < faixa[0] ? :abaixo : numero > faixa[1] ? :acima : :dentro] += 1
      end

      puts "  Onde esses números caem na faixa que importamos:"
      puts "    ABAIXO do menor que temos:  #{posicao[:abaixo]}   <- importação não foi longe o bastante"
      puts "    DENTRO da faixa:            #{posicao[:dentro]}   <- o Tiny não tem; qual sistema emitiu?"
      puts "    ACIMA do maior que temos:   #{posicao[:acima]}   <- mais nova que a última importação"
      puts "    série que não temos:        #{posicao[:serie_desconhecida]}"
      puts
      puts "  O que temos no banco por série:"

      Invoice.where(tenant_id: tenant.id)
             .group(:series)
             .pluck(Arel.sql("series, COUNT(*), MIN(NULLIF(regexp_replace(COALESCE(number,''),'\\D','','g'),'')::bigint), MAX(NULLIF(regexp_replace(COALESCE(number,''),'\\D','','g'),'')::bigint)"))
             .each do |serie, quantas, menor, maior|
               puts format("    série %-8s %5d notas, números de %s a %s",
                           serie.presence || "(vazia)", quantas, menor, maior)
             end

      puts
    end

    if sem_nota.any?
      puts "Vendas sem NF-e registrada no marketplace (#{sem_nota.size}):"

      sem_nota.first(10).each { |pedido| puts "  #{pedido.external_id}" }

      puts "  ... (#{sem_nota.size - 10} outras)" if sem_nota.size > 10

      puts
      puts "  Providência: perguntar ao cliente. Não é problema de software."
      puts
    end

    puts "Nada foi gravado."
  end
end
