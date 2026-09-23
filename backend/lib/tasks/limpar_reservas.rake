namespace :conciliacao do
  desc "Remove do razão as reservas que entraram como venda (APLICAR=1 grava)"
  task limpar_reservas: :environment do
    # Conserto de um estrago meu.
    #
    # Ao acrescentar a coluna RECORD_TYPE ao relatório de liberações, a
    # classificação — que preferia RECORD_TYPE a DESCRIPTION — passou a ler
    # "release" em TODA linha de liberação. `release` está na lista de venda, e
    # então reserva de garantia, de dívida e de devolução de envio entraram no
    # razão como VENDA. As vendas da base saltaram de 1.579 para 4.499.
    #
    # O código já foi corrigido. Isto remove o que a versão errada gravou.
    #
    # Só apaga o que a PRÓPRIA linha do relatório desmente: o lançamento tem a
    # linha guardada em `raw_payload`, e o DESCRIPTION dela diz que não é venda.
    # Nada é apagado por inferência de data, de valor ou de ausência de nota.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    aplicar = ENV["APLICAR"].to_s == "1"

    puts aplicar ? "MODO: GRAVANDO" : "MODO: SIMULAÇÃO (use APLICAR=1 para gravar)"
    puts

    # Os tipos que o leitor hoje mantém FORA do razão de propósito.
    fora = Marketplace::MercadoLivre::ReleaseEvents::MOVIMENTO_INTERNO

    puts "Tipos que não deviam estar no razão: #{fora.join(', ')}"
    puts

    intrusos = FinancialEntry
                 .where(tenant_id: tenant.id)
                 .where("jsonb_typeof(raw_payload) = 'object'")
                 .where("lower(raw_payload->>'DESCRIPTION') IN (?)", fora)

    total = intrusos.count

    puts "Lançamentos com DESCRIPTION de reserva: #{total}"

    if total.zero?
      puts
      puts "Nada a remover. Se as vendas ainda estão infladas, os lançamentos"
      puts "não têm a linha do relatório guardada — reimporte o período primeiro."

      next
    end

    por_tipo = intrusos.group(Arel.sql("lower(raw_payload->>'DESCRIPTION')")).count

    por_tipo.sort_by { |_, q| -q }.each { |tipo, quantas| puts format("  %-32s %d", tipo, quantas) }

    puts

    ids = intrusos.pluck(:id)

    # O recebível nasce do lançamento e carrega o mesmo external_id. É por ele
    # que se acha o que precisa sair junto.
    externos = intrusos.pluck(:external_id)

    recebiveis = ReceivableUnit.where(tenant_id: tenant.id, external_id: externos)

    # Recebível JÁ ligado a nota não é reserva: se tem nota, alguma coisa na
    # minha premissa está errada, e apagar seria destruir vínculo bom.
    com_nota = recebiveis.where.not(invoice_id: nil)

    if com_nota.exists?
      puts "PARANDO: #{com_nota.count} recebível(is) desses lançamentos tem NOTA ligada."
      puts "Reserva não tem nota. Ou a premissa está errada, ou o vínculo está errado —"
      puts "em qualquer caso não é apagando que se descobre. Me mostre esta saída."

      next
    end

    alocacoes = FinancialEntryAllocation.where(tenant_id: tenant.id, financial_entry_id: ids)

    repasses = PayoutBatch.where(tenant_id: tenant.id, financial_entry_id: ids)

    puts "Seriam removidos:"
    puts format("  lançamentos:            %d", total)
    puts format("  recebíveis:             %d", recebiveis.count)
    puts format("  alocações:              %d", alocacoes.count)
    puts format("  repasses apontando:     %d", repasses.count)
    puts

    if repasses.exists?
      puts "PARANDO: existe repasse cujo lançamento âncora é uma reserva."
      puts "Apagar o lançamento deixaria o repasse órfão. Isto precisa de decisão"
      puts "caso a caso — me mostre esta saída."

      next
    end

    puts format("  valor somado dos lançamentos: R$ %.2f", intrusos.sum(:amount).to_d)
    puts

    unless aplicar
      puts "Simulação. Nada foi removido."
      puts
      puts "Depois de aplicar, rode `rake conciliacao:vendas_sem_nf` para ver o número real."

      next
    end

    ActiveRecord::Base.transaction do
      apagadas = alocacoes.delete_all

      unidades = recebiveis.delete_all

      lancamentos = FinancialEntry.where(id: ids).delete_all

      puts "Removidos: #{lancamentos} lançamento(s), #{unidades} recebível(is), #{apagadas} alocação(ões)."
    end

    puts
    puts "Agora rode `rake conciliacao:vendas_sem_nf TENANT=#{tenant.id}`."
  end
end
