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

        faltando[numero] = { pedido: pedido.external_id, serie: dados["serie"] }
      end

    puts "Números que o marketplace informou e não estão no nosso banco: #{faltando.size}"
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

    # O cruzamento que responde.
    por_numero = notas.index_by { |nota| nota[:numero].to_s.sub(/\A0+/, "") }

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
      puts "  Nenhuma. Ou o período está errado, ou elas não estão no Tiny."
      puts "  Tente outro DE/ATE antes de concluir: eu já errei exatamente assim."
    end

    puts
    puts "Nada foi gravado."
  end
end
