namespace :omie do
  desc "O que exatamente têm as notas recusadas no envio (SOMENTE LEITURA)"
  task estado_das_recusadas: :environment do
    # Duas tentativas de reabrir a fila dessas notas voltaram "Faltam: 0", e as
    # duas vezes eu ajustei a condição por hipótese — primeiro achando que o
    # campo era NULL, depois que era string vazia. Nenhuma das duas olhou o
    # dado.
    #
    # Isto imprime o que as notas recusadas TÊM: as chaves do metadata, o
    # motivo gravado, e como cada campo do comprador está escrito. Sem chutar a
    # condição da próxima vez.
    #
    # Não imprime o documento nem o nome: só o formato — se existe, se é vazio,
    # quantos caracteres.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    recusadas = Invoice
                  .where(tenant_id: tenant.id)
                  .where("invoices.metadata->'omie_recusa' IS NOT NULL")

    puts "Notas com recusa gravada: #{recusadas.count}"
    puts

    if recusadas.none?
      puts "Nenhuma. Se a conciliação ainda acusa recusa, ela lê outro campo."

      next
    end

    puts "Motivo gravado:"

    recusadas.group(Arel.sql("invoices.metadata->'omie_recusa'->>'motivo'"))
             .count
             .each { |motivo, quantas| puts format("  %-24s %d", motivo.inspect, quantas) }

    puts
    puts "Como está o comprador nessas notas:"

    estados = Hash.new(0)

    recusadas.find_each do |nota|
      metadata = nota.metadata.to_h

      documento = metadata["comprador_documento"]

      estado =
        if !metadata.key?("comprador_documento") then "chave ausente"
        elsif documento.nil? then "nulo"
        elsif documento.to_s.strip.empty? then "vazio"
        else "preenchido (#{documento.to_s.gsub(/\D/, '').length} dígitos)"
        end

      estados[estado] += 1
    end

    estados.sort_by { |_, q| -q }.each { |estado, quantas| puts format("  %-32s %d", estado, quantas) }

    puts
    puts "Outras marcas nessas notas:"

    %w[tiny_recusa origem fiscal intermediador omie_codigo_lancamento].each do |chave|
      com = recusadas.where("invoices.metadata ? :c", c: chave).count

      puts format("  %-26s em %d de %d", chave, com, recusadas.count)
    end

    puts
    puts "Situação e origem:"

    recusadas.group(:status).count.each { |s, q| puts format("  status %-12s %d", s, q) }

    recusadas.group(Arel.sql("COALESCE(invoices.metadata->>'origem', '(tiny)')"))
             .count
             .each { |o, q| puts format("  origem %-12s %d", o, q) }

    puts
    puts "Uma delas, com as chaves do metadata (sem valores):"

    exemplo = recusadas.first

    puts "  NF #{exemplo.number}/#{exemplo.series} · #{exemplo.metadata.to_h.keys.sort.join(', ')}"

    puts
    puts "Nada foi gravado."
  end
end
