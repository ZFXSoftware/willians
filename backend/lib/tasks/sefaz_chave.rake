namespace :sefaz do
  desc "Busca uma nota na SEFAZ pela CHAVE, sem passar pela fila (NF=853559)"
  task por_chave: :environment do
    # Consulta por chave não usa NSU, então não sofre a penalidade de consumo
    # indevido — dá para rodar agora, sem esperar hora nenhuma.
    #
    # E responde a pergunta que está aberta desde ontem: a SEFAZ entrega o XML
    # de uma nota que a PRÓPRIA empresa emitiu? Se entregar, o caminho que o
    # usuário desenhou fecha — SPED dá as chaves, a SEFAZ dá os XMLs, e o
    # `xPed` dentro deles liga a nota à venda.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!


    certificado = CertificadoDigital.find_by(tenant_id: tenant.id)

    abort "Cadastre o certificado em Configurações antes." if certificado.blank?

    p12 = certificado.pkcs12

    abort "O certificado guardado não abriu. Recadastre-o." if p12.blank?

    escopo = Invoice.where(tenant_id: tenant.id).where.not(access_key: nil)

    notas = ENV["NF"].present? ? escopo.where(number: ENV["NF"].to_s.split(",").map(&:strip)) : escopo.limit(2)

    abort "Nenhuma nota com chave de acesso." if notas.none?

    cliente = Fiscal::Sefaz::DistribuicaoDfe.new(
      pkcs12: p12, cnpj: certificado.cnpj, uf_autor: ENV["UF"].presence || "35"
    )

    notas.each do |nota|
      chave = nota.access_key.to_s.gsub(/\D/, "")

      puts "=" * 70
      puts "NF #{nota.number}/#{nota.series} · chave #{chave}"

      resposta = cliente.consultar_chave(chave)

      puts "  SEFAZ: #{resposta.codigo} — #{resposta.motivo}"
      puts "  Documentos: #{resposta.documentos.size}"

      if resposta.documentos.empty?
        puts "  Resposta crua (400 primeiros caracteres):"
        puts "  #{resposta.bruto.to_s[0, 400]}"
        puts

        next
      end

      resposta.documentos.each do |doc|
        completo = doc.xml.include?("<infNFe") || doc.xml.include?("<nfeProc")

        puts format("  %-24s %s", doc.schema.to_s[0, 24],
                    completo ? "XML COMPLETO (#{doc.xml.bytesize} bytes)" : "resumo apenas")

        # A prova final: o número do pedido está no documento que a SEFAZ deu?
        pedidos = doc.xml.scan(%r{<xPed>([^<]+)</xPed>}).flatten +
                  doc.xml.scan(/xPed:\s*([A-Za-z0-9\-]+)/).flatten

        puts "    pedido no XML: #{pedidos.uniq.join(', ')}" if pedidos.any?

        intermediador = doc.xml[%r{<idCadIntTran>([^<]+)</idCadIntTran>}, 1]

        puts "    intermediador: #{intermediador}" if intermediador
      end

      puts

      sleep 2
    end

    puts "Como ler:"
    puts "  XML COMPLETO de nota nossa -> SPED dá as chaves, a SEFAZ dá os"
    puts "     documentos, e o xPed dentro deles liga a nota à venda."
    puts "  só resumo, ou recusa       -> a SEFAZ não entrega o que a própria"
    puts "     empresa emitiu, e o ERP continua sendo a fonte das vendas."
    puts
    puts "Nada foi gravado."
  end
end
