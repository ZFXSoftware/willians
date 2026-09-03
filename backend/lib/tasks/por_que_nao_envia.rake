namespace :omie do
  desc "Diz por que uma nota não está na fila de envio ao OMIE (NF=042289)"
  task por_que_nao_envia: :environment do
    # O contador diz "nada pendente" e a conciliação aponta notas sem título
    # que nunca foram enviadas. Uma condição do escopo as exclui, e adivinhar
    # qual já me custou várias voltas hoje.
    #
    # Esta tarefa avalia cada condição de `nao_enviadas_ao_omie` isoladamente e
    # mostra qual reprova.
    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    Current.tenant = tenant

    numeros = ENV["NF"].to_s.split(",").map(&:strip).compact_blank

    abort "Diga a nota: NF=042289 (ou várias, separadas por vírgula)." if numeros.empty?

    marco = Integracoes::Config.get("omie", :envio_a_partir_de, tenant: tenant).presence&.to_date

    puts "Marco de envio (envio_a_partir_de): #{marco || 'não definido'}"
    puts "Notas na fila hoje: #{Invoice.where(tenant_id: tenant.id).nao_enviadas_ao_omie(marco).count}"
    puts

    numeros.each do |numero|
      notas = Invoice.where(tenant_id: tenant.id, number: numero)

      if notas.none?
        puts "NF #{numero}: não existe no nosso banco."
        puts

        next
      end

      notas.each { |nota| explicar(nota, marco) }
    end

    puts "Nada foi gravado."
  end

  # Cada condição do escopo, avaliada sozinha. É a diferença entre "não está na
  # fila" e "não está na fila POR ISTO".
  def explicar(nota, marco)
    metadata = nota.metadata.to_h

    checagens = [
      [ "operation_type = sale", nota.operation_type == "sale", nota.operation_type.inspect ],
      [ "status != cancelled",   nota.status != "cancelled",    nota.status.inspect ],
      [ "sem código do OMIE",    metadata["omie_codigo_lancamento"].blank?,
        metadata["omie_codigo_lancamento"].inspect ],
      [ "sem recusa gravada",    metadata["omie_recusa"].blank?,
        metadata.dig("omie_recusa", "motivo").inspect ],
      [ "emitida a partir do marco", marco.blank? || (nota.issued_at.present? && nota.issued_at >= marco),
        nota.issued_at&.to_date.inspect ]
    ]

    puts "NF #{nota.number}/#{nota.series} · id #{nota.id}"

    checagens.each do |rotulo, passou, valor|
      puts format("  %-28s %-8s %s", rotulo, passou ? "ok" : "REPROVA", valor)
    end

    if checagens.all? { |_, passou, _| passou }
      puts "  -> Está na fila. Se o contador diz zero, o erro é no contador."
    else
      puts "  -> Fora da fila pelo(s) item(ns) marcado(s) REPROVA."
    end

    puts
  end
end
