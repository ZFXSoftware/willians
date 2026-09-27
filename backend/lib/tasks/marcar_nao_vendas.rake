namespace :conciliacao do
  desc "Marca (sem apagar) os recebíveis que nasceram de linha que não é venda (APLICAR=1 grava)"
  task marcar_nao_vendas: :environment do
    # Resíduo de uma regressão minha: ao acrescentar `RECORD_TYPE` ao relatório de
    # liberações, `tipo_da` passou a classificar toda linha como `release` e
    # portanto como VENDA. Reserva de disputa, frete, cashback e cancelamento de
    # mediação entraram no razão como receita.
    #
    # A limpeza da época pegou 3.379 e deixou 270 — R$ 40.011,06, dos quais 263
    # dentro de repasse. Era quase toda a diferença de R$ 43.298,17 que a
    # conciliação acusava, e nada disso é nota fiscal.
    #
    # NÃO apaga. Marca, e quem soma respeita a marca (`ReceivableUnit.vendas_reais`,
    # usada pelo `PayoutEngine` e pela conciliação). Apagar lançamento financeiro
    # para consertar número é hábito que esta base não pode ter: o registro do que
    # aconteceu é o que permite auditar depois.
    #
    # O código atual já não cria esses recebíveis — `VENDA = %w[payment release]` e
    # o resto vai para `@ignorados`. Isto é conserto do passado.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    aplicar = %w[true 1].include?(ENV["APLICAR"].to_s.strip.downcase)

    puts aplicar ? "MODO: GRAVANDO (marca, não apaga)" : "MODO: SIMULAÇÃO"
    puts

    # A linha do relatório é a fonte: `DESCRIPTION` diz o que o movimento É.
    # `RECORD_TYPE` diz apenas que é uma linha de liberação — foi confundir os dois
    # que causou tudo isto.
    suspeitos = FinancialEntry
                  .where(tenant_id: tenant.id, entry_type: "sale")
                  .where("jsonb_typeof(raw_payload) = 'object'")
                  .where("raw_payload->>'DESCRIPTION' IS NOT NULL")
                  .where("raw_payload->>'DESCRIPTION' NOT IN (?)", Marketplace::MercadoLivre::ReleaseEvents::VENDA)
                  .pluck(:external_id, Arel.sql("raw_payload->>'DESCRIPTION'"), :amount)

    if suspeitos.empty?
      puts "Nenhum recebível de venda vindo de linha que não é venda. Nada a fazer."

      next
    end

    por_descricao = suspeitos.group_by { |_, descricao, _| descricao }

    puts "Lançamentos de venda cuja linha do relatório não é venda:"
    por_descricao.sort_by { |_, lista| -lista.size }.each do |descricao, lista|
      puts format("  %-34s %5d · R$ %11.2f", descricao, lista.size,
                  lista.sum { |_, _, valor| valor.to_d })
    end
    puts

    externos = suspeitos.map(&:first)

    # Só os que ainda não estão marcados: rodar duas vezes não pode contar duas.
    alvos = ReceivableUnit.where(tenant_id: tenant.id, external_id: externos).vendas_reais.to_a

    em_repasse = FinancialEntryAllocation
                   .where(tenant_id: tenant.id, receivable_unit_id: alvos.map(&:id))
                   .where.not(payout_batch_id: nil)
                   .distinct
                   .pluck(:payout_batch_id, :receivable_unit_id)

    lotes = em_repasse.map(&:first).uniq

    puts format("Recebíveis a marcar:        %5d · R$ %11.2f", alvos.size,
                alvos.sum(BigDecimal("0")) { |u| u.gross_amount.to_d })
    puts format("Dentro de repasse:          %5d, em %d repasse(s)",
                em_repasse.map(&:last).uniq.size, lotes.size)
    puts

    descricao_por_externo = suspeitos.to_h { |externo, descricao, _| [ externo, descricao ] }

    next puts("Nada foi gravado. Use APLICAR=1 para marcar.") unless aplicar

    marcados = 0

    ReceivableUnit.transaction do
      alvos.each do |unidade|
        unidade.update!(metadata: (unidade.metadata || {}).merge(
          ReceivableUnit::MARCA_NAO_E_VENDA => {
            "descricao" => descricao_por_externo[unidade.external_id],
            "motivo" => "linha do relatório não é venda (regressão RECORD_TYPE)",
            "marcado_em" => Time.current
          }
        ))

        marcados += 1
      end
    end

    puts "Marcados: #{marcados}"
    puts
    puts "Os lançamentos e os recebíveis continuam no banco, com o motivo gravado."
    puts "O bruto dos #{lotes.size} repasse(s) afetados só se recalcula na próxima"
    puts "ingestão daquela janela — `marketplace:reimportar DE= ATE=` faz isso."
    puts
    puts "Repasses afetados: #{lotes.sort.join(', ')}" if lotes.any?
  end
end
