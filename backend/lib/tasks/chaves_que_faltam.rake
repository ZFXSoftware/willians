namespace :conciliacao do
  desc "As vendas sem nota nos repasses têm a CHAVE da NF-e? (SOMENTE LEITURA)"
  task chaves_que_faltam: :environment do
    # A chave de acesso é a identidade do documento fiscal: 44 dígitos que
    # carregam o CNPJ emissor, a série, o número e o mês. Verificado nesta
    # sessão em 261 de 261 casos, contra a própria chave.
    #
    # Ter a chave das vendas sem nota muda o que é possível: dá para buscar o XML
    # no Mercado Livre, ou criar a nota aqui com identidade verificável, em vez
    # de esperar que o Tiny passe a conhecê-la.
    #
    # Por REPASSE, porque é ali que a diferença aparece e é ali que alguém decide.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    lotes = PayoutBatch.where(tenant_id: tenant.id).order(paid_at: :desc)

    puts format("  %-6s %-12s %7s %8s %9s %14s",
                "id", "pago em", "s/ nota", "c/ chave", "sem chave", "valor s/ nota")

    total_com = 0
    total_sem = 0
    valor_com = BigDecimal("0")
    valor_sem = BigDecimal("0")

    lotes.each do |lote|
      unidades = lote
                   .financial_entry_allocations
                   .filter_map(&:receivable_unit)
                   .uniq
                   .select { |unidade| unidade.invoice_id.blank? }

      next if unidades.none?

      com_chave, sem_chave = unidades.partition do |unidade|
        dados = unidade.order&.metadata&.dig("nota_do_envio")

        dados.is_a?(Hash) && dados["chave"].to_s.gsub(/\D/, "").length == 44
      end

      total_com += com_chave.size
      total_sem += sem_chave.size

      soma = ->(lista) { lista.sum(BigDecimal("0")) { |u| u.gross_amount.to_d } }

      valor_com += soma.call(com_chave)
      valor_sem += soma.call(sem_chave)

      puts format("  #%-5d %-12s %7d %8d %9d %14.2f",
                  lote.id, lote.paid_at&.to_date, unidades.size,
                  com_chave.size, sem_chave.size, soma.call(unidades))
    end

    puts

    total = total_com + total_sem

    if total.zero?
      puts "Nenhuma venda sem nota nos repasses. Nada a fazer aqui."

      next
    end

    puts format("Vendas sem nota nos repasses: %d", total)
    puts format("  COM a chave da NF-e:  %d (%.1f%%) · R$ %.2f", total_com,
                100.0 * total_com / total, valor_com)
    puts format("  sem a chave:          %d (%.1f%%) · R$ %.2f", total_sem,
                100.0 * total_sem / total, valor_sem)
    puts

    # Sem chave tem duas razões, e elas pedem coisas diferentes.
    sem_marca = 0
    sem_nota_no_ml = 0

    lotes.each do |lote|
      lote.financial_entry_allocations.filter_map(&:receivable_unit).uniq.each do |unidade|
        next if unidade.invoice_id.present?

        dados = unidade.order&.metadata&.dig("nota_do_envio")

        next if dados.is_a?(Hash) && dados["chave"].to_s.gsub(/\D/, "").length == 44

        dados.is_a?(String) ? sem_nota_no_ml += 1 : sem_marca += 1
      end
    end

    # As COM chave deveriam estar ligadas: a nota existe e foi importada. Se
    # continuam sem vínculo, alguma coisa as impede — e cada causa pede outra
    # providência.
    puts "Das que TÊM chave, por que ainda estão sem vínculo:"

    causas = Hash.new(0)

    lotes.each do |lote|
      lote.financial_entry_allocations.filter_map(&:receivable_unit).uniq.each do |unidade|
        next if unidade.invoice_id.present?

        dados = unidade.order&.metadata&.dig("nota_do_envio")

        next unless dados.is_a?(Hash) && dados["chave"].to_s.gsub(/\D/, "").length == 44

        # Pela chave E por número+série, como `ReligarPeloEnvio` faz.
        #
        # Buscar só por `access_key` me fez anunciar "10 notas não estão no nosso
        # banco" quando estavam — sem a chave preenchida, que é justamente o que
        # o religamento preencheria se fosse ligar. A sonda inventou uma categoria
        # e eu fui consertar a importação por causa dela.
        numero = dados["numero"].to_s.sub(/\A0+/, "")

        serie = dados["serie"].to_s.sub(/\A0+/, "")

        nota = Invoice.where(tenant_id: tenant.id)
                      .where("regexp_replace(COALESCE(access_key,''), '\\D', '', 'g') = ?",
                             dados["chave"].to_s.gsub(/\D/, ""))
                      .first

        if nota.blank? && numero.present?
          nota = Invoice.where(tenant_id: tenant.id)
                        .where("regexp_replace(COALESCE(number,''), '\\A0+', '') = ?", numero)
                        .where("regexp_replace(COALESCE(series,''), '\\A0+', '') = ?", serie)
                        .first
        end

        causa = if nota.blank?
          "a nota não está aqui por chave NEM por número+série"
        elsif nota.status.to_s == "cancelled"
          "nota CANCELADA: o cliente precisa emitir outra"
        else
          "nota #{nota.status} sem vínculo: DEFEITO NOSSO"
        end

        causas[causa] += 1
      end
    end

    causas.sort_by { |_, q| -q }.each { |causa, quantas| puts format("  %-40s %d", causa, quantas) }

    puts
    puts "  cancelada é deixada solta de propósito: `soltar_canceladas!` a desgruda a"
    puts "  cada ciclo e `ReligarPeloEnvio` se recusa a religar — senão as duas brigariam."
    puts "  Por isso o mesmo repasse oscila entre execuções: liga, reimporta, solta."
    puts

    puts "Das que não têm chave:"
    puts format("  o marketplace disse que NÃO tem nota:   %d", sem_nota_no_ml)
    puts format("  ainda não foram perguntadas ao ciclo:   %d", sem_marca)
    puts
    puts "Como ler:"
    puts "  com chave  -> a nota existe e é identificável; dá para buscar o XML no"
    puts "     Mercado Livre ou criar o registro com identidade verificável."
    puts "  sem nota no ML -> ninguém emitiu. É conversa com o cliente."
    puts "  não perguntadas -> o ciclo chega nelas; espere uma volta."
    puts
    puts "Nada foi gravado."
  end
end
