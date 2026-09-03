namespace :conciliacao do
  desc "Pergunta ao Tiny se existe nota para as vendas pagas que estão sem ela (SOMENTE LEITURA)"
  task procurar_notas: :environment do
    # Sobraram vendas pagas cuja nota não está no nosso banco. Isso tem três
    # explicações com consertos diferentes, e só o Tiny sabe qual é:
    #
    #   1. a nota EXISTE no Tiny e nós não a importamos
    #      -> buraco na janela de importação; conserto nosso
    #   2. a nota existe, mas com outro número de pedido
    #      -> o elo numero_ecommerce não bate; conserto nosso, mais difícil
    #   3. o Tiny não tem nota para aquele pedido
    #      -> não foi emitida, e aí é assunto do cliente
    #
    # Uma consulta por pedido, com pausa. Por isso amostra: AMOSTRA=30 responde
    # a pergunta sem gastar dez minutos.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    Current.tenant = tenant

    amostra = (ENV["AMOSTRA"] || 30).to_i

    sem_nota = ReceivableUnit
                 .where(tenant_id: tenant.id, invoice_id: nil)
                 .where.not(order_id: nil)

    total = sem_nota.count

    puts "Vendas pagas sem nota no nosso banco: #{total}"
    puts

    # Como elas se distribuem no tempo.
    #
    # A primeira versão desta tarefa ordenava por data decrescente e conferiu
    # só as mais recentes — todas liberadas dois dias antes. Uma venda de
    # anteontem sem nota importada é banal; uma de julho é defeito. A amostra
    # enviesada respondia a pergunta errada com confiança total.
    por_mes = sem_nota.group(Arel.sql("to_char(expected_on, 'YYYY-MM')")).count

    puts "Distribuição por mês de liberação:"
    por_mes.sort.each { |mes, quantas| puts format("  %-10s %d", mes || "sem data", quantas) }
    puts

    puts "Conferindo #{[ amostra, total ].min} SORTEADAS no Tiny, uma por segundo."
    puts

    # Sorteio, e não as primeiras: qualquer ordenação fixa concentra a amostra
    # num período e esconde o resto.
    sem_nota = sem_nota.includes(:order).order(Arel.sql("RANDOM()"))

    if total.zero?
      puts "Nada a procurar."

      next
    end

    reader = Fiscal::Tiny::Reader.new

    achadas = 0
    ausentes = 0
    falhas = 0

    exemplos = { achada: [], ausente: [] }

    sem_nota.limit(amostra).each_with_index do |unidade, indice|
      referencia = unidade.order&.external_id

      next if referencia.blank?

      sleep 1

      puts "  #{indice + 1}/#{[ amostra, total ].min}..." if (indice % 10).zero?

      notas = reader.por_pedido(referencia)

      if notas.any?
        achadas += 1

        nota = notas.first

        if exemplos[:achada].size < 5
          exemplos[:achada] << format("pedido %s -> NF %s de %s (R$ %s)",
                                      referencia, nota[:numero], nota[:data_emissao], nota[:valor])
        end
      else
        ausentes += 1

        if exemplos[:ausente].size < 5
          exemplos[:ausente] << format("pedido %s, liberado em %s", referencia, unidade.expected_on)
        end
      end
    rescue StandardError => e
      falhas += 1

      Rails.logger.warn "[procurar_notas] #{referencia}: #{e.class} #{e.message}"
    end

    puts
    puts "Resultado da amostra:"
    puts format("  %-44s %d", "o Tiny TEM nota e nós não importamos", achadas)
    puts format("  %-44s %d", "o Tiny não tem nota para este pedido", ausentes)
    puts format("  %-44s %d", "falhas de consulta", falhas)
    puts

    exemplos[:achada].each { |exemplo| puts "    existe:   #{exemplo}" }
    exemplos[:ausente].each { |exemplo| puts "    não há:   #{exemplo}" }

    puts
    puts "Como ler:"
    puts "  maioria EXISTE  -> buraco na importação. Rode a importação do Tiny"
    puts "                     com janela larga (a tela de Integrações faz isso)."
    puts "  maioria NÃO HÁ  -> o cliente não emitiu nota para essas vendas, e"
    puts "                     nenhuma conciliação vai conseguir casá-las."
    puts
    puts "Nada foi gravado."
  end
end
