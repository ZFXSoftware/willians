namespace :omie do
  desc "O valor esperado do OMIE está certo? Audita título por título (SOMENTE LEITURA)"
  task auditar_esperado: :environment do
    # Pergunta do usuário: será que o valor esperado pelo OMIE está calculado
    # corretamente?
    #
    # O cálculo é: agrupar os títulos do OMIE pelo NÚMERO DA NOTA e somar
    # `valor_documento`. Duas coisas estragam isso, e a soma esconde as duas:
    #
    #   nota com MAIS DE UM título   envio repetido, ou lançamento manual por
    #                                cima do nosso. O esperado dobra, e o
    #                                repasse acusa diferença que não é dinheiro.
    #   título com valor DIFERENTE   da nota que temos: alguém editou no OMIE,
    #                                ou mandamos valor errado.
    #
    # Isto lê o OMIE e compara com as nossas notas. Não escreve em lugar nenhum.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    fim = ENV["ATE"].present? ? Date.parse(ENV["ATE"]) : Date.current

    inicio = ENV["DE"].present? ? Date.parse(ENV["DE"]) : (fim - 90)

    cliente = Omie::Client.new(tenant: tenant)

    unless Omie::Client.configured?
      abort "OMIE não configurado nesta empresa."
    end

    puts "Janela: #{inicio} a #{fim}"
    puts

    leitor = Omie::Readers::ReceivableTotals.new(client: cliente)

    totais = leitor.call(start_date: inicio, end_date: fim)

    detalhes = leitor.detalhes

    puts "Referências com título no OMIE: #{totais.size}"
    puts format("Soma de todos os títulos: R$ %.2f", totais.values.sum)
    puts

    # 1. A mesma nota com mais de um título.
    repetidas = detalhes.select { |_, lista| lista.size > 1 }

    puts "Referências com MAIS DE UM título: #{repetidas.size}"

    if repetidas.any?
      soma_extra = repetidas.sum { |_, lista| lista.sum { |t| t[:valor] } - lista.first[:valor] }

      puts format("  o quanto isso infla o esperado: R$ %.2f", soma_extra)
      puts

      repetidas.sort_by { |_, lista| -lista.size }.first(10).each do |referencia, lista|
        puts format("    NF %-10s %d títulos, somando R$ %.2f", referencia, lista.size,
                    lista.sum { |t| t[:valor] })

        lista.first(4).each do |titulo|
          puts format("        R$ %10.2f · parcela %-6s · venc %-12s · %s",
                      titulo[:valor], titulo[:parcela] || "—", titulo[:vencimento] || "—",
                      titulo[:codigo].to_s.truncate(40))
        end
      end

      puts
      puts "  Parcela numerada (1/2, 2/2) somando o valor da nota é NORMAL."
      puts "  Títulos com o MESMO valor e sem parcela é envio em duplicata."
      puts
    end

    # 2. O título vale o mesmo que a nossa nota?
    nossas = Invoice
               .where(tenant_id: tenant.id)
               .where.not(number: nil)
               .pluck(:number, :total_amount, :status)
               .to_h { |numero, valor, status| [ Omie::Readers::ReceivableTotals.normalizar(numero), [ valor.to_d, status ] ] }

    divergentes = []

    sem_nota_nossa = []

    totais.each do |referencia, valor|
      nossa = nossas[referencia]

      next sem_nota_nossa << referencia if nossa.nil?

      next if (nossa[0] - valor).abs < BigDecimal("0.01")

      divergentes << [ referencia, nossa[0], valor, nossa[1] ]
    end

    puts "Título cujo valor NÃO bate com a nossa nota: #{divergentes.size}"

    if divergentes.any?
      puts

      puts format("    %-10s %14s %14s %12s  %s", "NF", "nossa nota", "título OMIE", "diferença", "situação")

      divergentes.sort_by { |d| -(d[1] - d[2]).abs }.first(15).each do |referencia, nosso, omie, situacao|
        puts format("    %-10s %14.2f %14.2f %12.2f  %s", referencia, nosso, omie, omie - nosso, situacao)
      end

      puts "    ... (#{divergentes.size - 15} outras)" if divergentes.size > 15
      puts
    end

    puts "Título no OMIE sem nota correspondente no nosso banco: #{sem_nota_nossa.size}"

    if sem_nota_nossa.any?
      puts "  #{sem_nota_nossa.first(10).join(', ')}"
      puts "  (pode ser título de outro sistema do cliente, ou nota que não importamos)"
    end

    puts
    puts "Como ler:"
    puts "  esperado inflado por duplicata -> o repasse acusa diferença NEGATIVA,"
    puts "     como se o OMIE tivesse mais dinheiro que o marketplace pagou."
    puts "  título valendo mais que a nota -> alguém editou no OMIE, ou o envio"
    puts "     mandou valor de outra coisa."
    puts
    puts "Nada foi gravado."
  end
end
