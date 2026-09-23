namespace :tiny do
  desc "As notas que faltam estão entre as que a importação DESCARTA? (SOMENTE LEITURA)"
  task notas_descartadas: :environment do
    # O cliente disse que nunca usou outro ERP, o que derruba a minha conclusão
    # de que as 287 notas teriam sido emitidas fora do Tiny.
    #
    # E havia uma pista à vista: a importação de 01/06 a 01/08 leu 1962 notas do
    # Tiny, criou ZERO, e ignorou 432 por `sem_referencia` — o `InvoiceSync`
    # descarta toda nota cujo `numero_ecommerce` esteja vazio, porque é por ele
    # que a nota se liga ao pedido do marketplace.
    #
    # Se as que faltam estão entre as descartadas, o Tiny sempre as teve e o
    # problema é nosso: estamos jogando fora nota fiscal por não saber a qual
    # pedido ela pertence.
    #
    # Isto LISTA o período no Tiny e cruza com os números que o marketplace nos
    # deu. Não importa nada, não grava nada.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    fim = ENV["ATE"].present? ? Date.parse(ENV["ATE"]) : Date.current

    inicio = ENV["DE"].present? ? Date.parse(ENV["DE"]) : (fim - 30)

    puts "Período no Tiny: #{inicio} a #{fim}"
    puts

    # Os números que o marketplace disse existir e que não estão no nosso banco.
    faltando = {}

    Order
      .where(tenant_id: tenant.id)
      .where("jsonb_typeof(orders.metadata->'nota_do_envio') = 'object'")
      .find_each do |pedido|
        dados = pedido.metadata["nota_do_envio"]

        numero = dados["numero"].to_s.sub(/\A0+/, "")

        next if numero.blank?

        next if Invoice.where(tenant_id: tenant.id)
                       .where("regexp_replace(COALESCE(number,''), '\\A0+', '') = ?", numero)
                       .exists?

        faltando[numero] = { pedido: pedido.external_id, serie: dados["serie"], data: dados["data"] }
      end

    puts "Números que o marketplace informou e não estão no nosso banco: #{faltando.size}"
    puts

    # Faixa de NÚMERO e de DATA do que falta, por série.
    #
    # Sem isso, "o Tiny lista 0 neste período" não diz se eu pedi o período
    # errado ou se as notas não estão lá. A faixa localiza: se o que falta é
    # anterior ao que o Tiny devolve, o período é que está errado.
    faltando.group_by { |_, dados| dados[:serie] }.each do |serie, itens|
      numeros = itens.map { |numero, _| numero.to_i }.sort

      datas = itens.filter_map { |_, dados| (Date.parse(dados[:data].to_s) rescue nil) }.sort

      puts format("  série %-4s %4d nota(s) · números de %s a %s · emitidas de %s a %s",
                  serie.presence || "?", itens.size, numeros.first, numeros.last,
                  datas.first || "?", datas.last || "?")
    end

    puts

    if faltando.none?
      puts "Nada faltando. Nada a investigar aqui."

      next
    end

    notas = Fiscal::Tiny::Reader.new.notas_fiscais(start_date: inicio, end_date: fim)

    puts "Notas que o Tiny lista no período: #{notas.size}"
    puts

    sem_referencia = notas.select { |nota| nota[:numero_ecommerce].blank? }

    puts "  delas, SEM numero_ecommerce (que a importação descarta): #{sem_referencia.size}"
    puts

    # E a faixa do que o Tiny DEVOLVEU, para comparar com a do que falta.
    puts "  Faixa do que o Tiny devolveu, por série:"

    notas.group_by { |nota| nota[:serie] }.each do |serie, lista|
      numeros = lista.map { |nota| nota[:numero].to_s.sub(/\A0+/, "").to_i }.sort

      datas = lista.filter_map { |nota| nota[:data_emissao] }.sort

      puts format("    série %-4s %5d nota(s) · números de %s a %s · de %s a %s",
                  serie.presence || "?", lista.size, numeros.first, numeros.last,
                  datas.first || "?", datas.last || "?")
    end

    puts

    por_numero = notas.index_by { |nota| nota[:numero].to_s.sub(/\A0+/, "") }

    # CONTROLE DA LISTAGEM, antes do cruzamento.
    #
    # A peça que nunca testei: a listagem do Tiny para este período está
    # COMPLETA? As notas que já temos vieram dela, então todas as nossas do
    # período deveriam aparecer aqui. As que não aparecerem provam que a
    # listagem trunca — e aí "o Tiny não tem" é falso para qualquer conclusão.
    nossas_do_periodo = Invoice
                          .where(tenant_id: tenant.id)
                          .where(issued_at: inicio.beginning_of_day..fim.end_of_day)
                          .where.not(number: nil)
                          .pluck(:number, :series)

    faltam_na_listagem = nossas_do_periodo.reject do |numero, _serie|
      por_numero.key?(numero.to_s.sub(/\A0+/, ""))
    end

    puts "Controle da listagem — as NOSSAS notas do período aparecem nela?"
    puts format("  nossas notas emitidas no período: %d", nossas_do_periodo.size)
    puts format("  que a listagem NÃO devolveu:      %d", faltam_na_listagem.size)

    if faltam_na_listagem.any?
      puts
      puts "  A listagem está INCOMPLETA: ela não devolve nem notas que vieram dela."
      puts "  Exemplos: #{faltam_na_listagem.first(8).map { |n, s| "#{n}/#{s}" }.join(', ')}"
      puts
      puts "  Nada abaixo sustenta conclusão sobre o Tiny ter ou não as notas."
    end

    puts

    # O cruzamento que responde.

    achadas = faltando.keys & por_numero.keys

    puts "Das #{faltando.size} que faltam, o Tiny lista #{achadas.size} neste período."
    puts

    if achadas.any?
      com_referencia = achadas.count { |n| por_numero[n][:numero_ecommerce].present? }

      puts format("  com numero_ecommerce (deveriam ter entrado):  %d", com_referencia)
      puts format("  SEM numero_ecommerce (a importação descarta): %d", achadas.size - com_referencia)
      puts

      puts "  Exemplos:"

      achadas.first(10).each do |numero|
        nota = por_numero[numero]

        puts format("    NF %-10s série %-4s de %-12s · numero_ecommerce: %s · pedido no ML: %s",
                    nota[:numero], nota[:serie], nota[:data_emissao],
                    nota[:numero_ecommerce].presence || "VAZIO",
                    faltando[numero][:pedido])
      end

      puts
      puts "  Se a maioria está SEM numero_ecommerce, o Tiny sempre teve essas notas"
      puts "  e nós as descartamos por não saber a qual pedido pertencem. O elo"
      puts "  existe do outro lado: o marketplace nos deu número, série e valor."
    else
      # "Zero" com as faixas se SOBREPONDO não é ausência: é o cruzamento errado.
      #
      # Aconteceu: o que falta vai de 40075 a 46159 na série 2 e o Tiny devolveu
      # 40037 a 41905 na mesma série. Uma nota numerada 40075 tinha que estar
      # ali. Em vez de escolher entre "período errado" e "não existe", isto
      # mostra o caso: o número exato, o que o Tiny tem perto dele, e como cada
      # lado escreve o número.
      puts "  Nenhuma — e as faixas se sobrepõem, o que aponta para o CRUZAMENTO."
      puts

      puts "  Os dez primeiros que faltam, contra o que o Tiny tem perto:"

      chaves_tiny = por_numero.keys.map(&:to_i).sort

      faltando.keys.sort_by(&:to_i).first(10).each do |numero|
        alvo = numero.to_i

        vizinhos = chaves_tiny.min_by(3) { |k| (k - alvo).abs }.sort

        puts format("    falta %-8s (ML série %-3s) · Tiny tem por perto: %s · idêntico? %s",
                    numero, faltando[numero][:serie], vizinhos.join(", "),
                    por_numero.key?(numero) ? "SIM" : "não")
      end

      puts

      puts "  E como cada lado escreve o número, cru:"

      puts format("    ML (metadata):  %s", faltando.keys.first(5).inspect)

      puts format("    Tiny (listagem): %s", notas.first(5).map { |n| n[:numero] }.inspect)

      puts
      puts "  Número igual em um lado e não no outro = formato. Faixas próximas mas"
      puts "  sem coincidir = são numerações diferentes, e o número do ML não é o"
      puts "  número da nota no Tiny."
    end

    puts
    puts "Nada foi gravado."
  end
end
