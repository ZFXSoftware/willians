namespace :fiscal do
  desc "Lê o XML das NF-e e completa os campos fiscais (LIMITE=200; grava)"
  task ler_xmls: :environment do
    # O ciclo lê 50 notas por volta, e o cliente tem 7.395. A cada cinco minutos isso são
    # doze horas para varrer o histórico — certo para o regime permanente, lento para a
    # primeira vez. Esta tarefa faz a primeira vez.
    #
    # GRAVA, e só no bloco `fiscal` da nota: completa o que está vazio e não apaga o que o
    # ERP disse. As exceções — CST do ICMS e ST — estão nomeadas em
    # `Fiscal::Nfe::Enriquecimento::PREFERE_O_XML`, com o motivo de cada uma.
    #
    # Uma requisição por nota. A recusa é gravada, então rodar de novo continua de onde
    # parou em vez de bater nas mesmas notas sem documento.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    limite = (ENV["LIMITE"].presence || 200).to_i

    total = Invoice.where(tenant_id: tenant.id).count

    pendentes = Invoice.where(tenant_id: tenant.id).where("metadata->'xml' IS NULL").count

    puts format("Notas: %d · sem leitura de XML: %d · lendo até %d nesta volta", total, pendentes, limite)
    puts

    resumo = Fiscal::Nfe::Enriquecimento.new(tenant: tenant, limite: limite).call

    puts format("  lidas:       %5d", resumo[:lidas])
    puts format("  completadas: %5d", resumo[:completadas])
    puts format("  recusadas:   %5d  (nota sem documento autorizado, não se tenta de novo)", resumo[:recusadas])
    puts format("  sem caminho: %5d", resumo[:sem_caminho])
    puts format("  erros:       %5d", resumo[:erros])
    puts

    # O que MUDOU na base, que é a razão de existir da leitura.
    com_natureza = Invoice.where(tenant_id: tenant.id)
                          .where("metadata->'fiscal'->>'natureza_operacao' IS NOT NULL").count

    com_csosn = Invoice.where(tenant_id: tenant.id)
                       .where("jsonb_array_length(COALESCE(metadata->'fiscal'->'csosns', '[]'::jsonb)) > 0").count

    com_pis = Invoice.where(tenant_id: tenant.id)
                     .where("metadata->'fiscal'->>'valor_pis' IS NOT NULL").count

    lidas = Invoice.where(tenant_id: tenant.id).where("metadata->'xml'->>'situacao' = 'lido'").count

    puts "Cobertura agora, sobre as #{total} notas:"
    puts format("  natureza da operação: %5d", com_natureza)
    puts format("  CSOSN:                %5d", com_csosn)
    puts format("  PIS/COFINS:           %5d", com_pis)
    puts format("  lidas do documento:   %5d", lidas)
    puts

    restam = Invoice.where(tenant_id: tenant.id).where("metadata->'xml' IS NULL").count

    puts restam.positive? ? "Faltam #{restam}. Rode de novo para continuar." : "Nenhuma nota pendente."
  end
end
