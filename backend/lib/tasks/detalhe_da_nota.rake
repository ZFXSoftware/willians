namespace :tiny do
  desc "O que o Tiny devolve sobre uma nota, inteiro (SOMENTE LEITURA)"
  task detalhe_da_nota: :environment do
    # O `IntermediadorSync` já busca este detalhe nota por nota e guarda APENAS
    # o intermediador. Se o desconto, o frete e a situação tributária por item
    # estiverem aqui, a conciliação fiscal não precisa de 4221 downloads de XML
    # — precisa parar de descartar o que já chega.
    #
    # Imprime tudo. Filtrar o que mostrar já esconde a resposta duas vezes nesta
    # investigação: as colunas do relatório e o bloco de totais da NF-e.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    numero = ENV["NOTA"].to_s.strip.sub(/\A0+/, "")

    nota =
      if numero.present?
        Invoice.where(tenant_id: tenant.id)
               .where("regexp_replace(COALESCE(number,''), '\\A0+', '') = ?", numero)
               .first
      else
        Invoice.where(tenant_id: tenant.id)
               .where.not(external_id: nil)
               .where.not(status: :cancelled)
               .order(Arel.sql("RANDOM()"))
               .first
      end

    abort "Não achei a nota. Use NOTA=<número> ou deixe em branco para sortear." if nota.blank?

    puts "NF #{nota.number}/#{nota.series} · id no Tiny #{nota.external_id} · nosso valor R$ #{format('%.2f', nota.total_amount.to_d)}"
    puts

    detalhe = Fiscal::Tiny::V2Client.new.obter_nota(nota.external_id)

    abort "O Tiny não devolveu esta nota." if detalhe.blank?

    puts "Campos do cabeçalho (#{detalhe.keys.size}):"
    puts

    # Aninhados no fim: o cabeçalho é o que interessa primeiro, e uma lista de
    # itens no meio empurra o resto para fora da tela.
    simples, aninhados = detalhe.partition { |_, valor| !valor.is_a?(Hash) && !valor.is_a?(Array) }

    simples.sort.each { |chave, valor| puts format("  %-28s %s", chave, valor.to_s.truncate(90)) }

    puts

    aninhados.each do |chave, valor|
      puts "#{chave} (#{valor.is_a?(Array) ? "#{valor.size} item(ns)" : 'objeto'}):"

      amostra = valor.is_a?(Array) ? valor.first(2) : [ valor ]

      amostra.each_with_index do |item, i|
        conteudo = item.is_a?(Hash) ? (item.values.first.is_a?(Hash) ? item.values.first : item) : item

        puts "  --- #{i + 1} ---"

        if conteudo.is_a?(Hash)
          conteudo.sort.each { |k, v| puts format("    %-26s %s", k, v.to_s.truncate(80)) }
        else
          puts "    #{conteudo.to_s.truncate(200)}"
        end
      end

      puts "  ... (#{valor.size - 2} outros)" if valor.is_a?(Array) && valor.size > 2

      puts
    end

    puts "O que a conciliação fiscal procura aqui:"

    procurados = %w[desconto valor_desconto frete valor_frete csosn cst cfop ncm
                    icms icms_st pis cofins ipi aliquota situacao_tributaria
                    valor_icms valor_icms_st base_icms tributos]

    achados = detalhe.keys.select { |k| procurados.any? { |p| k.to_s.downcase.include?(p) } }

    puts achados.any? ? "  no cabeçalho: #{achados.join(', ')}" : "  nada no cabeçalho"

    nos_itens = aninhados.flat_map do |_, valor|
      Array(valor.is_a?(Array) ? valor : [ valor ]).flat_map do |item|
        conteudo = item.is_a?(Hash) ? (item.values.first.is_a?(Hash) ? item.values.first : item) : {}

        conteudo.is_a?(Hash) ? conteudo.keys.select { |k| procurados.any? { |p| k.to_s.downcase.include?(p) } } : []
      end
    end.uniq

    puts nos_itens.any? ? "  nos itens:    #{nos_itens.join(', ')}" : "  nada nos itens"

    puts
    puts "Nada foi gravado."
  end
end
