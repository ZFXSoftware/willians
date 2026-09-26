namespace :fiscal do
  desc "Há duas notas nossas com o mesmo número? Como elas entraram? (SOMENTE LEITURA)"
  task notas_repetidas: :environment do
    # A auditoria do OMIE achou três referências com dois títulos. Uma é a
    # duplicata velha (o mesmo `codigo_lancamento_integracao` aceito duas vezes).
    # As outras duas têm códigos DIFERENTES — `WLL-NF-7820` e `WLL-NF-9773` —, e
    # código diferente significa nota diferente no NOSSO banco com o mesmo número.
    #
    # Isso é pior que duplicata de envio: é a importação criando registro novo
    # para documento que já existe. Com ~700 notas de junho ainda por importar, o
    # mecanismo precisa ser entendido antes de continuar.
    #
    # A pergunta não é "quantas" — é COMO entraram. Por isso a saída mostra
    # origem, série, chave e status de cada lado do par: é a diferença entre elas
    # que diz qual peneira falhou.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    # Agrupa pelo número normalizado, que é a chave que o OMIE usa para casar
    # título com nota — é ali que a duplicata se manifesta.
    grupos = Invoice
               .where(tenant_id: tenant.id)
               .where.not(number: nil)
               .group_by { |nota| nota.number.to_s.sub(/\A0+/, "") }
               .select { |_, lista| lista.size > 1 }

    puts "Números com mais de uma nota no nosso banco: #{grupos.size}"
    puts

    if grupos.empty?
      puts "Nenhum. As duplicatas do OMIE vêm de outro caminho."

      next
    end

    # Por série, porque número repetido em SÉRIES diferentes é legítimo: são
    # documentos distintos. Repetido na MESMA série é que é defeito.
    mesma_serie = 0
    series_diferentes = 0

    grupos.sort.first(20).each do |numero, lista|
      series = lista.map { |nota| nota.series.to_s.sub(/\A0+/, "") }.uniq

      legitimo = series.size == lista.size

      legitimo ? series_diferentes += 1 : mesma_serie += 1

      puts format("  NF %-10s %d notas%s", numero, lista.size,
                  legitimo ? "  (séries diferentes: documentos distintos)" : "  <- MESMA SÉRIE")

      lista.sort_by(&:id).each do |nota|
        chave = nota.access_key.to_s.gsub(/\D/, "")

        puts format("      ##%-6d série %-4s %-10s origem %-14s emitida %s  R$ %9.2f  chave ...%s%s",
                    nota.id, nota.series.presence || "—", nota.status,
                    nota.metadata.to_h["origem"].presence || "(sem origem)",
                    nota.issued_at&.to_date, nota.total_amount.to_d,
                    chave.presence&.last(6) || "vazia",
                    nota.metadata.to_h["omie_codigo_lancamento"].present? ? " · JÁ NO OMIE" : "")
      end

      puts
    end

    puts format("Pares na MESMA série (defeito):      %d", mesma_serie)
    puts format("Pares em séries diferentes (ok):     %d", series_diferentes)
    puts

    # E o que o importador do Mercado Livre teria feito: a peneira dele compara
    # por chave, ou por número junto com a série. Se os dois lados do par têm
    # chave e elas DIFEREM, a peneira não tinha como saber — são documentos
    # distintos para ela. Se um lado tem chave vazia, foi por aí que passou.
    puts "Das repetidas na mesma série, o que a peneira da importação via:"

    sem_chave = 0
    chaves_diferentes = 0

    grupos.each do |_, lista|
      series = lista.map { |nota| nota.series.to_s.sub(/\A0+/, "") }.uniq

      next if series.size == lista.size

      chaves = lista.map { |nota| nota.access_key.to_s.gsub(/\D/, "") }

      if chaves.any?(&:blank?)
        sem_chave += 1
      elsif chaves.uniq.size > 1
        chaves_diferentes += 1
      end
    end

    puts format("  algum lado com chave VAZIA:        %d  <- a comparação por chave não alcança", sem_chave)
    puts format("  chaves diferentes entre si:        %d  <- são documentos distintos de verdade?", chaves_diferentes)
    puts

    puts "Como ler:"
    puts "  mesma série + chave vazia num lado -> a peneira comparou chave contra"
    puts "     nada e caiu no número+série; se a série gravada divergir da que o"
    puts "     marketplace informou, ela cria de novo."
    puts "  mesma série + chaves diferentes -> ou o marketplace reemitiu o"
    puts "     documento, ou uma das chaves está errada. Aí não é peneira: é dado."
    puts
    puts "Nada foi gravado."
  end
end
