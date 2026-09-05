namespace :omie do
  desc "Presta contas de cada nota: subiu, não subiu, ou foi excluída por quê (SOMENTE LEITURA)"
  task balanco_do_envio: :environment do
    # "Nada pendente" tem duas leituras opostas: tudo subiu, ou quase tudo foi
    # excluído por alguma regra. São cinco filtros agindo sobre 4162 notas, e
    # o contador devolve só o resultado final.
    #
    # Aqui cada nota cai em EXATAMENTE UM balde, e os baldes somam o total —
    # se não somarem, há caso que eu não previ, e isso também precisa aparecer.
    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!


    marco = Integracoes::Config.get("omie", :envio_a_partir_de, tenant: tenant).presence&.to_date

    notas = Invoice.where(tenant_id: tenant.id)

    total = notas.count

    puts "Marco de envio: #{marco || 'não definido'}"
    puts "Notas no banco: #{total}"
    puts

    baldes = {}

    baldes["já tem título no OMIE"] =
      notas.where("invoices.metadata->>'omie_codigo_lancamento' IS NOT NULL").count

    restantes = notas.where("invoices.metadata->>'omie_codigo_lancamento' IS NULL")

    baldes["recusadas por nós (sem valor / sem CPF)"] =
      restantes.where("invoices.metadata->'omie_recusa' IS NOT NULL").count

    restantes = restantes.where("invoices.metadata->'omie_recusa' IS NULL")

    baldes["canceladas no Tiny"] = restantes.where(status: :cancelled).count

    restantes = restantes.where.not(status: :cancelled)

    baldes["devolução ou ajuste (não vira título a receber)"] =
      restantes.where.not(operation_type: :sale).count

    restantes = restantes.where(operation_type: :sale)

    if marco
      baldes["emitidas antes do marco"] =
        restantes.where("invoices.issued_at < ? OR invoices.issued_at IS NULL", marco).count

      restantes = restantes.where(issued_at: marco..)
    end

    baldes["NA FILA para subir"] = restantes.count

    baldes.each { |rotulo, quantas| puts format("  %-46s %d", rotulo, quantas) }

    puts
    puts format("  %-46s %d", "soma dos baldes", baldes.values.sum)

    if baldes.values.sum != total
      puts "  ATENÇÃO: a soma não bate com o total. Há caso não previsto aqui."
    end

    puts
    puts "Das que já subiram, por canal:"

    Invoice
      .where(tenant_id: tenant.id)
      .where("invoices.metadata->>'omie_codigo_lancamento' IS NOT NULL")
      .group(Arel.sql("COALESCE(invoices.metadata->'intermediador'->>'nome', '(não lido)')"))
      .count
      .sort_by { |_, quantas| -quantas }
      .each { |canal, quantas| puts format("  %-30s %d", canal, quantas) }

    puts
    puts "Todo canal com nota vira título no OMIE, inclusive os que o sistema"
    puts "não concilia. Se o cliente não quiser título de venda própria ou de"
    puts "canal sem integração, isso é decisão dele e hoje não existe filtro."
    puts
    puts "Nada foi gravado."
  end
end
