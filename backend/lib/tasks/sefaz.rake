namespace :sefaz do
  # Os eventos que aparecem na distribuição. Ciência e confirmação são de quem
  # RECEBE; cancelamento e carta de correção são de quem EMITE — e é essa
  # distinção que responde se a SEFAZ nos conta sobre as notas da empresa.
  EVENTOS = {
    "110110" => "carta de correção",
    "110111" => "cancelamento",
    "210200" => "confirmação da operação",
    "210210" => "ciência da operação",
    "210220" => "desconhecimento",
    "210240" => "operação não realizada"
  }.freeze

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

    leitura = LeituraSefaz.find_or_create_by!(tenant_id: tenant.id)

    # Bloqueio é respeitado, não registrado.
    #
    # Insistir antes da hora transforma penalidade ocasional em bloqueio
    # recorrente — e o antiabuso da SEFAZ conta por CNPJ, então isso atrapalha
    # também quem mais consome essa fila.
    if leitura.bloqueada?
      puts "A SEFAZ pediu para esperar. Faltam #{leitura.minutos_de_espera} minuto(s)."
      puts "Último motivo: #{leitura.ultimo_motivo}"
      puts
      puts "Nada foi consultado."

      next
    end

    # Só para frente.
    #
    # Existiu um modo de sondagem que pedia NSU atrás do marcador para descobrir
    # se o mês passado ainda estava na fila. A resposta veio na primeira
    # tentativa — 656 imediato — e o custo foi uma hora de bloqueio. A fila não
    # anda para trás, e oferecer um botão que só serve para levar castigo é
    # convite a repetir o erro.
    nsu = ENV["NSU"].present? ? ENV["NSU"].to_i : leitura.ultimo_nsu

    puts "Continuando do NSU #{nsu}#{nsu.zero? ? ' (primeira leitura desta empresa)' : ''}"
    puts "Faltam #{leitura.faltam || '?'} documento(s) para o fim da fila." if leitura.max_nsu
    puts

    lotes = (ENV["LOTES"] || 1).to_i

    total = Hash.new(0)
    esquemas = Hash.new(0)
    datas_vistas = []
    resposta = nil

    lotes.times do |volta|
      resposta = cliente.consultar(ultimo_nsu: nsu)

      break if resposta.codigo == "656"

      resposta.documentos.each do |doc|
        total[papel_no_documento(doc.xml, cnpj)] += 1

        esquemas[doc.schema.to_s.sub(/_v.*/, "")] += 1

        data = emitida_em(doc.xml)

        datas_vistas << data if data
      end

      nsu = resposta.ultimo_nsu.to_i

      leitura.avancar!(resposta)

      puts format("  lote %d: NSU até %s · %d documento(s)", volta + 1, resposta.ultimo_nsu, resposta.documentos.size)

      break if resposta.documentos.empty? || nsu >= resposta.max_nsu.to_i

      # A SEFAZ limita a frequência. Uma pausa entre lotes é o que separa
      # varredura de consumo indevido.
      sleep 2
    end

    puts

    # 656 é a SEFAZ dizendo "você já leu até aqui, não recomece do zero".
    #
    # Ela penaliza com uma hora de espera, e o `ultNSU` devolvido é a resposta:
    # é de onde continuar. Pedir do zero foi erro meu no desenho — a consulta
    # é uma fila incremental, não uma busca.
    if resposta.codigo == "656"
      # Sempre. O bloqueio é fato da SEFAZ, não modo nosso: na primeira vez eu
      # deixei de gravá-lo numa execução "que não gravava nada", e a tarefa
      # seguinte foi consultar dentro da penalidade e levou outra.
      leitura.bloquear!(resposta)

      puts "Resposta da SEFAZ: 656 — #{resposta.motivo}"
      puts
      puts "A conexão FUNCIONOU: o certificado foi aceito e a SEFAZ respondeu."
      puts "Este CNPJ já consumiu até o NSU #{resposta.ultimo_nsu} — há pelo menos"
      puts "#{resposta.ultimo_nsu.to_i} documentos distribuídos para ele."
      puts
      puts "O marcador foi guardado: a próxima chamada continua do #{leitura.ultimo_nsu}"
      puts "sozinha, sem NSU na linha de comando. Basta esperar a hora."
      puts
      puts "Nada foi gravado."

      next
    end

    puts "Resposta final: #{resposta.codigo} — #{resposta.motivo}"
    puts "Marcador agora: #{leitura.reload.ultimo_nsu} · maior NSU: #{resposta.max_nsu}"
    puts "Faltam #{leitura.faltam} documento(s) para o fim da fila."
    puts

    if total.empty?
      puts "Nenhum documento nos lotes pedidos."
      puts
      puts "Resposta crua (primeiros 600 caracteres):"
      puts resposta.bruto.to_s[0, 600]

      next
    end

    puts "Datas vistas: #{datas_vistas.min} a #{datas_vistas.max}" if datas_vistas.any?
    puts

    puts "Tipos de documento:"
    esquemas.sort_by { |_, quantos| -quantos }.each { |nome, quantos| puts format("  %-24s %d", nome, quantos) }

    puts
    puts "Papel da empresa:"
    total.sort_by { |_, quantos| -quantos }.each { |papel, quantos| puts format("  %-34s %d", papel, quantos) }

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

  # A data do documento, para mapear NSU em tempo.
  #
  # Cada tipo usa uma tag: nota tem `dhEmi`, evento tem `dhEvento`, e o resumo
  # de evento pode trazer só `dhRegEvento`. Procurar apenas `dhEmi` fez um lote
  # inteiro de eventos parecer ter uma data só — e eu concluí, disso, que a
  # retenção era de quinze dias. Era a minha leitura que estava cega.
  def emitida_em(xml)
    %w[dhEmi dEmi dhEvento dhRegEvento dhRecbto].each do |tag|
      valor = xml[%r{<#{tag}>([^<]+)</#{tag}>}, 1]

      return valor.to_s[0, 10] if valor.present?
    end

    nil
  end

  # O CNPJ da empresa aparece como emitente ou como destinatário neste XML?
  def papel_no_documento(xml, cnpj)
    # Evento não tem <emit>/<dest>: tem o CNPJ do AUTOR e o tipo. Tratá-lo como
    # "outro papel" jogava 28 documentos numa gaveta cega — e eram a maioria
    # do lote.
    if xml.include?("<resEvento") || xml.include?("<procEventoNFe") || xml.include?("<evento")
      tipo = xml[%r{<tpEvento>(\d+)</tpEvento>}, 1]

      autor = xml[%r{<CNPJ>(\d+)</CNPJ>}, 1]

      return "evento #{EVENTOS[tipo] || tipo} (#{autor == cnpj ? 'nosso' : 'de terceiro'})"
    end

    emitente = xml[%r{<emit>.*?<CNPJ>(\d+)</CNPJ>}m, 1]

    destinatario = xml[%r{<dest>.*?<CNPJ>(\d+)</CNPJ>}m, 1]

    return "EMITENTE" if emitente == cnpj

    return "destinatário" if destinatario == cnpj

    # Resumo de NF-e (resNFe) traz só o emitente, sem o grupo completo.
    return "EMITENTE (resumo)" if xml.include?("<resNFe") && xml.include?(cnpj.to_s)

    "outro papel"
  end
end
