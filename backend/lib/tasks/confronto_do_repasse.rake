namespace :conciliacao do
  desc "Confronta o que a conciliação GRAVOU sobre um repasse com o que o banco diz AGORA (SOMENTE LEITURA)"
  task confronto_do_repasse: :environment do
    # Duas leituras do mesmo fato discordaram: `chaves_que_faltam` disse 7
    # vendas sem nota no repasse #27, e a observação da conciliação, gravada
    # minutos depois, disse 11. O código das duas percorre o MESMO caminho
    # (`financial_entry_allocations → receivable_unit → uniq`, sem nota quando
    # `invoice_id` é nulo), então elas não podem discordar sobre a mesma base no
    # mesmo instante.
    #
    # Sobram três explicações, e elas pedem providências opostas: a base mudou
    # entre as duas (a `conciliacao:rodar` faz ingestão antes de conciliar); o
    # registro exibido é de uma execução anterior e o `inalterado?` não o
    # atualizou; ou uma das leituras não mede o que eu penso.
    #
    # Escolher por dedução aqui já custou quatro diagnósticos errados nesta
    # base. Então: o número de agora, o número gravado, e QUANDO cada registro
    # foi escrito — lado a lado, no mesmo processo.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    id = ENV["REPASSE"].to_i

    lote = if id.positive?
      PayoutBatch.find_by(tenant_id: tenant.id, id: id)
    else
      PayoutBatch.where(tenant_id: tenant.id).order(paid_at: :desc).first
    end

    next puts("Repasse não encontrado. Use REPASSE=<id>.") if lote.blank?

    puts "Repasse ##{lote.id}, pago em #{lote.paid_at&.to_date}"
    puts

    alocacoes = lote.financial_entry_allocations.to_a

    unidades = alocacoes.filter_map(&:receivable_unit).uniq

    sem_nota = unidades.select { |unidade| unidade.invoice_id.blank? }

    puts "AGORA, pelo mesmo caminho que as duas leituras usam:"
    puts format("  alocações:            %d", alocacoes.size)
    puts format("  recebíveis distintos: %d", unidades.size)
    puts format("  sem nota:             %d · R$ %.2f",
                sem_nota.size, sem_nota.sum(BigDecimal("0")) { |u| u.gross_amount.to_d })
    puts

    # Recebível criado DEPOIS da conciliação explica sozinho a discordância: o
    # repasse ganhou venda nova entre as duas leituras.
    if sem_nota.any?
      recentes = sem_nota.max_by(3, &:created_at)

      puts "  os sem nota mais recentes (criado em / ligado em):"
      recentes.each do |unidade|
        puts format("    %-22s criado %s · atualizado %s · R$ %.2f",
                    unidade.external_id.to_s.truncate(22),
                    unidade.created_at&.strftime("%d/%m %H:%M"),
                    unidade.updated_at&.strftime("%d/%m %H:%M"),
                    unidade.gross_amount.to_d)
      end
      puts
    end

    # O outro lado: o que ficou GRAVADO, e quando. `conciliated_at` é carimbado
    # também quando nada muda (`carimbar_inalterados!`), então ele diz quando foi
    # CONFERIDO; `created_at` diz quando aquele texto foi ESCRITO. A distância
    # entre os dois é a idade da observação que a tela mostra.
    registros = ConciliacaoRegistro
                  .where(tenant_id: tenant.id, payout_batch_id: lote.id)
                  .order(conciliated_at: :desc, id: :desc)
                  .limit(3)

    puts "GRAVADO (mais recente primeiro):"

    next puts("  nenhum registro para este repasse.") if registros.none?

    registros.each do |registro|
      # A decomposição fica ANINHADA em `conciliation_metadata["decomposicao"]`,
      # e não no topo. Ler o topo devolve vazio em tudo — e vazio aqui parece
      # exatamente com "o motor não gravou". Eu li errado e anunciei ao usuário
      # que as colunas da tela estavam em branco em produção; estavam gravadas
      # desde sempre. O controller lê pelo caminho certo (registros_controller
      # linha 73), então a tela nunca esteve quebrada.
      metadados = registro.conciliation_metadata.to_h["decomposicao"].to_h

      puts format("  #%-8d run %-7s status %-14s diferença %10.2f",
                  registro.id, registro.conciliation_run_id || "-",
                  registro.status || "(fora do enum)", registro.diferenca.to_d)
      puts format("      escrito em %s · conferido em %s",
                  registro.created_at&.strftime("%d/%m %H:%M:%S"),
                  registro.conciliated_at&.strftime("%d/%m %H:%M:%S"))

      if metadados.any?
        puts format("      sem_nota %s (%s vendas) · sem_titulo %s (%s notas) · ajustes %s · resíduo %s",
                    metadados["sem_nota"], metadados["vendas_sem_nota"],
                    metadados["sem_titulo"], metadados["notas_sem_titulo"],
                    metadados["ajustes"], metadados["residuo"])
      else
        puts "      sem decomposição gravada (confira se o topo do metadata tem valor_omie:" \
             " se tiver, é a decomposição que falta, não o metadata inteiro)"
      end

      puts format("      %s", registro.observacao.to_s.truncate(150))
    end

    puts
    puts "Como ler:"
    puts "  se `sem nota` de AGORA bate com `vendas_sem_nota` do registro mais recente,"
    puts "     as duas leituras concordam e a diferença estava no TEMPO entre elas."
    puts "  se não bate e `escrito em` é antigo, o registro é velho: o motor achou"
    puts "     que nada mudou e a tela está mostrando a conta de outra execução."
    puts "  se não bate e `escrito em` é de agora, então uma das duas leituras não"
    puts "     mede o que eu penso, e o caminho é comparar recebível por recebível."
    puts
    puts "Nada foi gravado."
  end
end
