namespace :fiscal do
  desc "Devolve à fila as notas marcadas como recusadas por BLOQUEIO do ERP (APLICAR=1 grava)"
  task desmarcar_bloqueios: :environment do
    # Conserto de um erro meu, de hoje. A primeira varredura de XML rodou sem pausa, o Tiny
    # devolveu "API Bloqueada - Excedido o número de acessos" e o meu código gravou isso
    # como RECUSA em 1.292 de 1.310 notas. Elas sairiam da fila por um erro que passa em
    # minutos.
    #
    # `DetalheDaNota` já tinha resolvido exatamente isso e deixado escrito no arquivo. Eu
    # escrevi um serviço novo e repeti o erro que a base já tinha corrigido — o serviço
    # agora distingue bloqueio de recusa e interrompe o lote, e esta tarefa desfaz o
    # estrago.
    #
    # Apaga SÓ a marca `xml` que eu mesmo gravei, e só nas notas cujo motivo é bloqueio.
    # Nada do cliente é tocado: o bloco `fiscal` fica como está, e nota com recusa de
    # verdade (código 34, "Nota Fiscal não autorizada") continua marcada.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    aplicar = %w[true 1].include?(ENV["APLICAR"].to_s.strip.downcase)

    puts aplicar ? "MODO: GRAVANDO" : "MODO: SIMULAÇÃO"
    puts

    recusadas = Invoice
                  .where(tenant_id: tenant.id)
                  .where("metadata->'xml'->>'situacao' = 'recusado'")
                  .to_a

    por_motivo = recusadas.group_by do |nota|
      motivo = nota.metadata.to_h.dig("xml", "motivo").to_s

      if motivo.match?(Fiscal::Nfe::Enriquecimento::BLOQUEIO)
        :bloqueio
      elsif motivo.match?(/não autorizada|nao autorizada/i)
        :nao_autorizada
      else
        :outro
      end
    end

    puts "Notas marcadas como recusadas, por motivo real:"
    por_motivo.each do |motivo, lista|
      puts format("  %-16s %5d", motivo, lista.size)
    end
    puts

    alvos = por_motivo[:bloqueio].to_a

    if alvos.empty?
      puts "Nenhuma marcada por bloqueio. Nada a desfazer."

      next
    end

    puts format("A devolver à fila: %d nota(s)", alvos.size)
    puts

    next puts("Nada foi gravado. Use APLICAR=1 para desfazer.") unless aplicar

    Invoice.transaction do
      alvos.each do |nota|
        # `except` e não `merge` com nil: a chave tem que DESAPARECER, senão a fila
        # (`metadata->'xml' IS NULL`) continua sem enxergar a nota.
        nota.update!(metadata: nota.metadata.to_h.except("xml"))
      end
    end

    puts format("%d nota(s) de volta à fila.", alvos.size)
    puts
    puts "O bloco `fiscal` de cada uma ficou intacto, e as recusas de verdade continuam marcadas."
    puts "Rode `fiscal:ler_xmls LIMITE=60` — com pausa de 1s, o bloqueio não deve voltar."
  end
end
