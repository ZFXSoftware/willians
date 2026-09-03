namespace :conciliacao do
  desc "Abre uma remessa e mostra venda a venda de onde vem a diferença (SOMENTE LEITURA)"
  task remessa: :environment do
    # A pergunta que esta tarefa responde: quando um repasse aparece com
    # divergência grande, é porque as vendas erradas foram penduradas nele, ou
    # porque os dois lados da comparação medem coisas diferentes?
    #
    # São causas opostas. A primeira se conserta agrupando certo; a segunda,
    # comparando a mesma grandeza. Sem abrir venda a venda, as duas produzem o
    # mesmo sintoma — uma diferença grande e sem explicação na tela.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    quantos = (ENV["QUANTOS"] || 3).to_i

    registros =
      if ENV["REPASSE"].present?
        ConciliacaoRegistro.where(tenant_id: tenant.id, payout_batch_id: ENV["REPASSE"])
      else
        # Só o estado ATUAL de cada repasse.
        #
        # Cada execução grava um registro por repasse — é o histórico de como
        # ele foi conferido ao longo do tempo. Ordenar por tamanho da diferença
        # sem esse recorte devolve o pior registro que já existiu, de qualquer
        # data, e eu li a data dele como se fosse a última execução: concluí
        # que a conciliação estava parada há dias quando ela rodava.
        ConciliacaoRegistro
          .where(tenant_id: tenant.id, status: "divergent")
          .where(id: ConciliacaoRegistro.ids_dos_ultimos(tenant.id))
          .where.not(payout_batch_id: nil)
          .order(Arel.sql("ABS(COALESCE(diferenca, 0)) DESC"))
          .limit(quantos)
      end

    # "Nenhum divergente" tem duas leituras opostas — tudo bateu, ou nada foi
    # comparado — e repasse sem cobertura completa vira `manual_review`, não
    # `divergent`. Sem o quadro por status, a mensagem é um beco sem saída.
    atuais = ConciliacaoRegistro
               .where(tenant_id: tenant.id)
               .where(id: ConciliacaoRegistro.ids_dos_ultimos(tenant.id))

    puts "Situação atual dos repasses:"
    atuais.group(:status).count.sort_by { |_, quantos| -quantos }.each do |status, quantos|
      puts format("  %-16s %d", status, quantos)
    end
    puts

    # O motivo de CADA um, agrupado.
    #
    # Abrir só o maior respondia "por que este não fechou", e a pergunta é
    # "por que treze não fecharam" — que pode ter três respostas diferentes ao
    # mesmo tempo, com consertos opostos.
    puts "Por que cada repasse não fechou:"

    atuais.where(status: "manual_review").group_by { |r| resumir(r.observacao) }
          .sort_by { |_, lista| -lista.size }
          .each { |motivo, lista| puts format("  %-58s %d", motivo, lista.size) }

    puts

    if registros.none?
      puts "Nenhum repasse DIVERGENTE."
      puts

      if atuais.where(status: "manual_review").any?
        puts "Mas há repasses em 'manual_review': são os que não puderam ser comparados"
        puts "por falta de cobertura. Abrindo o maior deles para ver o motivo:"
        puts

        registro = atuais.where(status: "manual_review").order(valor: :desc).first

        lote = PayoutBatch.find_by(id: registro&.payout_batch_id)

        imprimir_remessa(tenant, lote, registro) if lote
      elsif atuais.where(status: "matched").any?
        puts "Todos os repasses comparáveis CONFEREM com o OMIE."
      end

      next
    end

    # Um repasse tem um registro POR EXECUÇÃO da conciliação — é o histórico
    # de como ele foi conferido ao longo do tempo. Sem desduplicar, os três
    # "mais divergentes" podem ser o mesmo repasse impresso três vezes.
    vistos = Set.new

    registros.each do |registro|
      next unless vistos.add?(registro.payout_batch_id)

      lote = PayoutBatch.find_by(id: registro.payout_batch_id)

      next if lote.blank?

      imprimir_remessa(tenant, lote, registro)
    end

    puts "Como ler:"
    puts "  diferença ≈ soma dos fretes/ajustes das vendas -> os dois lados medem"
    puts "     grandezas diferentes (valor da venda no marketplace x valor da NF)."
    puts "  vendas com data muito anterior ao repasse       -> agrupamento errado:"
    puts "     o repasse recolheu recebível que ele não pagou."
    puts
    puts "Nada foi gravado."
  end

  def imprimir_notas_sem_titulo(tenant, unidades)
    notas = unidades.filter_map(&:invoice).uniq

    return if notas.empty?

    cliente = Omie::Client.configured? ? Omie::Client.new : nil

    return puts "  (OMIE não configurado; pulei a conferência de títulos.)" unless cliente

    # A MESMA busca que a conciliação usa, com a mesma janela.
    janela_inicio = notas.filter_map(&:issued_at).min&.to_date || Date.current

    totais = Omie::Readers::ReceivableTotals.new(client: cliente).call(
      start_date: janela_inicio - 30, end_date: Date.current
    )

    faltando = notas.reject do |nota|
      chave = Omie::Readers::ReceivableTotals.normalizar(nota.number)

      chave.present? && totais.key?(chave)
    end

    puts format("  Notas sem título no OMIE: %d de %d", faltando.size, notas.size)

    return if faltando.empty?

    puts format("    %-10s %-12s %-12s %s", "NF", "emitida", "enviada?", "código do OMIE")

    faltando.first(10).each do |nota|
      codigo = nota.metadata.to_h["omie_codigo_lancamento"]

      recusa = nota.metadata.to_h.dig("omie_recusa", "motivo")

      puts format("    %-10s %-12s %-12s %s",
                  nota.number, nota.issued_at&.to_date,
                  recusa ? "recusada" : (codigo ? "sim" : "NÃO"),
                  codigo || recusa || "—")
    end

    puts "    ... (#{faltando.size - 10} outras)" if faltando.size > 10

    puts
    puts "  enviada=sim e sem título -> nós criamos, a busca não acha: é a JANELA."
    puts "  enviada=NÃO              -> o contador de pendentes é que está errado."
    puts "  recusada                 -> nunca vai ter título, e é esperado."
    puts
  end

  # A observação nomeia quantidades ("3 nota(s)..."), e agrupar pelo texto cru
  # criaria um grupo por repasse. O que interessa é a CLASSE do motivo.
  def resumir(observacao)
    texto = observacao.to_s

    case texto
    when /fração que coube/    then "nota de pacote partida entre repasses (rateada)"
    when /Nenhuma das/         then "nenhuma nota deste repasse tem título no OMIE"
    when /têm título no OMIE/  then "parte das notas ainda não tem título no OMIE"
    when /sem nota fiscal/     then "vendas sem nota fiscal"
    when ""                    then "(sem observação)"
    else texto.truncate(56)
    end
  end

  def imprimir_remessa(tenant, lote, registro)
    extrato = lote.financial_entry

    puts "=" * 78
    puts "Repasse ##{lote.id} · ref #{lote.external_id} · pago em #{lote.paid_at}"
    # A data do registro importa: se ele é anterior às correções do motor, o
    # número é fantasma de uma regra que já não vale. Agora é sempre o registro
    # MAIS RECENTE deste repasse — antes vinha o de maior diferença, de
    # qualquer época.
    puts "Conferido em #{registro.conciliated_at} (execução ##{registro.conciliation_run_id})"

    quantas = ConciliacaoRegistro.where(tenant_id: tenant.id, payout_batch_id: lote.id).count

    puts "Este repasse já foi conferido #{quantas} vez(es)."
    puts
    puts format("  dinheiro que entrou (extrato):  R$ %.2f", extrato&.amount.to_d)
    puts format("  lote: bruto R$ %.2f · taxa R$ %.2f · líquido R$ %.2f",
                lote.gross_amount.to_d, lote.fee_amount.to_d, lote.net_amount.to_d)
    puts format("  conciliação: nosso R$ %.2f · OMIE %s · diferença R$ %.2f",
                registro.valor.to_d,
                registro.conciliation_metadata&.dig("valor_omie") || "—",
                registro.diferenca.to_d)
    puts

    # A frase que diz POR QUE não fechou. O motor já a calculava e a tela já a
    # mostra; esta tarefa imprimia tudo menos ela, que é o que se procura.
    puts "  MOTIVO: #{registro.observacao}"
    puts

    unidades = lote
                 .financial_entry_allocations
                 .filter_map(&:receivable_unit)
                 .uniq

    puts "  #{unidades.size} venda(s) penduradas nesta remessa:"
    puts

    puts format("    %-24s %-12s %12s %-10s %12s", "pedido", "liberado em", "venda (ML)", "NF", "valor NF")

    soma_ml = BigDecimal("0")
    soma_nf = BigDecimal("0")

    # A nota do PACOTE vale por várias vendas: somá-la uma vez por venda
    # inflaria o total e faria parecer que as notas valem mais que as vendas.
    # O motor já deduplica; esta soma precisava fazer o mesmo.
    notas_somadas = Set.new

    unidades.sort_by { |u| u.expected_on || Date.new(1970) }.first(40).each do |unidade|
      nota = unidade.invoice

      soma_ml += unidade.gross_amount.to_d
      soma_nf += nota.total_amount.to_d if nota && notas_somadas.add?(nota.id)

      puts format("    %-24s %-12s %12.2f %-10s %12.2f",
                  unidade.order&.external_id.to_s[0, 24],
                  unidade.expected_on,
                  unidade.gross_amount.to_d,
                  nota&.number || "sem NF",
                  nota&.total_amount.to_d)
    end

    puts "    ... (#{unidades.size - 40} outras)" if unidades.size > 40
    puts

    # A decomposição que separa as duas causas.
    puts format("  soma das vendas no marketplace: R$ %.2f", soma_ml)
    puts format("  soma das notas fiscais:         R$ %.2f", soma_nf)
    puts format("  diferença entre as duas:        R$ %.2f", soma_ml - soma_nf)
    puts

    # As notas deste repasse que a conciliação NÃO encontrou no OMIE.
    #
    # "Todas as notas já foram enviadas" e "parte das notas não tem título"
    # não podem ser verdade ao mesmo tempo. Uma das duas está errada, e a
    # diferença está no carimbo: se a nota tem `omie_codigo_lancamento`, nós
    # criamos o título e a BUSCA é que não o acha — provavelmente a janela de
    # emissão. Se não tem, ela nunca foi enviada, e o contador é que mente.
    imprimir_notas_sem_titulo(tenant, unidades)

    # De qual canal são as notas penduradas neste repasse.
    #
    # O dinheiro é certamente do Mercado Livre — os recebíveis nascem do
    # extrato daquela conta e o lote filtra por ela. A NOTA é outra história: o
    # vínculo passa pelo pedido, e a atribuição de canal está errada em massa.
    #
    # Se aparecer Shopee ou TikTok aqui, uma nota de outro canal entrou na
    # conciliação do Mercado Livre, e o valor esperado está contaminado.
    canais = unidades
               .filter_map { |u| u.invoice }
               .group_by { |nota| (nota.metadata || {}).dig("intermediador", "nome") || "(não lido)" }
               .transform_values(&:size)

    if canais.any?
      puts "  Canal das notas deste repasse:"
      canais.sort_by { |_, quantas| -quantas }.each { |canal, quantas| puts format("    %-24s %d", canal, quantas) }

      intrusos = canais.keys.reject { |nome| nome.nil? || nome.match?(/mercado livre|1333228810|\(não lido\)/i) }

      puts "    ATENÇÃO: #{intrusos.join(', ')} não deveriam estar aqui." if intrusos.any?

      puts
    end

    datas = unidades.filter_map(&:expected_on)

    if datas.any?
      puts format("  vendas liberadas entre %s e %s (repasse em %s)",
                  datas.min, datas.max, lote.paid_at.to_date)

      antigas = datas.count { |data| data < lote.paid_at.to_date - 30 }

      puts "  #{antigas} venda(s) liberadas há mais de 30 dias do repasse" if antigas.positive?
    end

    puts
  end
end
