namespace :sefaz do
  desc "Pergunta à SEFAZ se ela devolve as notas que a empresa EMITIU (SOMENTE LEITURA)"
  task testar: :environment do
    # O fato que falta para decidir a arquitetura: o NFeDistribuicaoDFe devolve
    # as notas emitidas pela própria empresa, ou só aquelas em que ela é
    # destinatária? As fontes divergem, e uma chamada real decide.
    #
    # Nada é gravado. Isto é uma pergunta à SEFAZ, não uma importação.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    Current.tenant = tenant

    p12, cnpj = carregar_certificado(tenant)

    uf = ENV["UF"].presence || "35"

    puts "CNPJ do certificado: #{cnpj}"
    puts "UF do consultante:   #{uf} (use UF=xx se não for São Paulo)"
    puts "Ambiente:            #{ENV['HOMOLOGACAO'] ? 'homologação' : 'produção'}"
    puts

    cliente = Fiscal::Sefaz::DistribuicaoDfe.new(
      pkcs12: p12, cnpj: cnpj, uf_autor: uf, producao: ENV["HOMOLOGACAO"].blank?
    )

    resposta = cliente.consultar(ultimo_nsu: (ENV["NSU"] || 0).to_i)

    puts "Resposta da SEFAZ: #{resposta.codigo} — #{resposta.motivo}"
    puts "Último NSU lido: #{resposta.ultimo_nsu} · maior NSU disponível: #{resposta.max_nsu}"
    puts "Documentos neste lote: #{resposta.documentos.size}"
    puts

    if resposta.documentos.empty?
      puts "Nenhum documento. Isso pode ser fim de fila (cStat 137) ou consulta"
      puts "no ambiente errado — leia o motivo acima antes de concluir."
      puts
      puts "Resposta crua (primeiros 800 caracteres):"
      puts resposta.bruto.to_s[0, 800]

      next
    end

    # A PERGUNTA. Para cada NF-e devolvida, o CNPJ da empresa está como
    # emitente ou como destinatário?
    papeis = Hash.new(0)

    resposta.documentos.each_with_index do |doc, indice|
      papel = papel_no_documento(doc.xml, cnpj)

      papeis[papel] += 1

      next if indice >= 5

      puts format("  NSU %-8s %-28s papel: %s", doc.nsu, doc.schema, papel)
    end

    puts "  ... (#{resposta.documentos.size - 5} outros)" if resposta.documentos.size > 5

    puts
    puts "Papel da empresa nos documentos devolvidos:"
    papeis.sort_by { |_, quantos| -quantos }.each { |papel, quantos| puts format("  %-24s %d", papel, quantos) }

    puts
    puts "Como ler:"
    puts "  aparece EMITENTE      -> a SEFAZ devolve as notas da própria empresa,"
    puts "     e ela serve como fonte fiscal independente de ERP."
    puts "  só DESTINATÁRIO       -> ela só entrega o que foi emitido CONTRA a"
    puts "     empresa. Serve de rede de segurança, não de fonte das vendas."
    puts
    puts "Nada foi gravado."
  end

  # O certificado pode vir do banco (quando já cadastrado) ou de um arquivo,
  # que é o caso deste primeiro teste.
  #
  # A senha por ENV fica no histórico do shell. SENHA_ARQUIVO é o caminho
  # preferido justamente por isso.
  def carregar_certificado(tenant)
    guardado = CertificadoDigital.find_by(tenant_id: tenant.id)

    if guardado && ENV["PFX"].blank?
      p12 = guardado.pkcs12

      abort "O certificado guardado não abriu. Recadastre-o." if p12.blank?

      return [ p12, guardado.cnpj ]
    end

    caminho = ENV["PFX"].presence

    abort "Diga o certificado: PFX=/caminho/certificado.pfx" if caminho.blank?

    abort "Arquivo não encontrado: #{caminho}" unless File.exist?(caminho)

    senha =
      if ENV["SENHA_ARQUIVO"].present?
        File.read(ENV["SENHA_ARQUIVO"]).strip
      else
        puts "AVISO: senha via ENV fica no histórico do shell. Prefira SENHA_ARQUIVO=/caminho."
        ENV["SENHA"].to_s
      end

    abort "Diga a senha: SENHA_ARQUIVO=/caminho/senha.txt (ou SENHA=)" if senha.blank?

    p12 =
      begin
        OpenSSL::PKCS12.new(File.binread(caminho), senha)
      rescue OpenSSL::PKCS12::PKCS12Error => e
        abort "Não consegui abrir o certificado: #{e.message}. Confira o arquivo e a senha."
      end

    [ p12, ENV["CNPJ"].presence || p12.certificate.subject.to_s[/\d{14}/] ]
  end

  # O CNPJ da empresa aparece como emitente ou como destinatário neste XML?
  def papel_no_documento(xml, cnpj)
    return "resumo de evento" if xml.include?("<resEvento")

    emitente = xml[%r{<emit>.*?<CNPJ>(\d+)</CNPJ>}m, 1]

    destinatario = xml[%r{<dest>.*?<CNPJ>(\d+)</CNPJ>}m, 1]

    return "EMITENTE" if emitente == cnpj

    return "destinatário" if destinatario == cnpj

    # Resumo de NF-e (resNFe) traz só o emitente, sem o grupo completo.
    return "EMITENTE (resumo)" if xml.include?("<resNFe") && xml.include?(cnpj.to_s)

    "outro papel"
  end
end
