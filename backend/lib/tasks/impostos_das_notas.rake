require "csv"

namespace :fiscal do
  desc "Que imposto cada lado carrega: a NF-e e o relatório do marketplace (SOMENTE LEITURA)"
  task impostos_das_notas: :environment do
    # Primeiro passo da conciliação fiscal, e é medição, não desenho.
    #
    # A pergunta tem dois lados que nunca foram olhados:
    #
    #   na NOTA  — o que está destacado de ICMS, ST, PIS, COFINS e IPI, e qual
    #              o regime (CRT) e a situação por item (CSOSN/CST)
    #   no DINHEIRO — o TAXES_AMOUNT do relatório de liberações, que a
    #              documentação do Mercado Pago define como "impostos coletados
    #              para retenções"
    #
    # O regime muda tudo: no Simples Nacional a nota não destaca ICMS nem
    # PIS/COFINS — o tributo sai no DAS, mensal, por receita bruta. Se for esse
    # o caso, "quais impostos foram pagos nas notas" tem uma resposta
    # incômoda: nenhum, e a conciliação fiscal passa a ser outra coisa.
    #
    # Imprime o bloco de totais CRU da primeira nota. Escolher quais campos
    # mostrar já esconde a resposta — aconteceu duas vezes nesta base.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    quantas = (ENV["QUANTAS"] || 8).to_i

    # ---------------------------------------------------------------- a nota

    escopo = Invoice
               .where(tenant_id: tenant.id)
               .where.not(external_id: nil)
               .where.not(status: :cancelled)

    # NOTAS=042372,852410 examina as que interessam em vez de sortear.
    #
    # É o caminho para testar uma suspeita concreta: o bloco de totais tem
    # `vDesc`, e um desconto na própria nota faria `vNF` sair menor que `vProd`
    # exatamente no valor do desconto — que é a forma dos R$ 4,00 e R$ 6,00 que
    # sobraram sem explicação na conciliação do repasse.
    pedidas = ENV["NOTAS"].to_s.split(",").map { |n| n.strip.sub(/\A0+/, "") }.reject(&:empty?)

    notas =
      if pedidas.any?
        escopo.where("regexp_replace(COALESCE(number,''), '\\A0+', '') IN (?)", pedidas).to_a
      else
        # Amostra aleatória, e não as mais recentes: a ponta da lista já me
        # enganou quatro vezes nesta base.
        escopo.order(Arel.sql("RANDOM()")).limit(quantas).to_a
      end

    if pedidas.any?
      faltando = pedidas - notas.map { |n| n.number.to_s.sub(/\A0+/, "") }

      puts "Não achei no banco: #{faltando.join(', ')}" if faltando.any?
    end

    if notas.none?
      abort "Nenhuma nota para examinar."
    end

    puts "Lendo o XML de #{notas.size} nota(s), amostra aleatória."
    puts

    client = Fiscal::Tiny::V2Client.new

    totais = Hash.new { |h, k| h[k] = BigDecimal("0") }

    regimes = Hash.new(0)

    situacoes = Hash.new(0)

    falhas = 0

    primeiro = true

    notas.each do |nota|
      xml = client.obter_xml(nota.external_id)

      # O bloco de totais da NF-e. É onde o documento diz, ele mesmo, quanto de
      # cada tributo carrega.
      bloco = xml[%r{<ICMSTot>(.*?)</ICMSTot>}m, 1]

      if primeiro && bloco
        puts "Bloco <ICMSTot> da NF #{nota.number}, inteiro e sem filtro meu:"

        bloco.strip.split(/<(?=v|q)/).each { |t| puts "    <#{t.strip}" unless t.strip.empty? }

        puts

        primeiro = false
      end

      # CRT: 1 = Simples Nacional, 2 = Simples com excesso de sublimite,
      # 3 = Regime Normal. É o campo que decide se a nota destaca tributo.
      regimes[xml[%r{<CRT>(\d)</CRT>}, 1] || "(ausente)"] += 1

      # A situação tributária por item: CSOSN no Simples, CST no normal.
      xml.scan(%r{<(CSOSN|CST)>(\d+)</\1>}).each { |tag, valor| situacoes["#{tag} #{valor}"] += 1 }

      next if bloco.blank?

      campos = bloco.scan(%r{<(v[A-Za-z]+)>([\d.]+)</\1>}).to_h

      campos.each { |campo, valor| totais[campo] += valor.to_d }

      # Uma linha por nota quando foram pedidas: é a comparação que decide se o
      # desconto da nota explica a diferença contra o valor da venda.
      if pedidas.any?
        puts format("  NF %-10s vProd %9.2f · vDesc %8.2f · vFrete %8.2f · vNF %9.2f · nosso banco %9.2f",
                    nota.number, campos["vProd"].to_d, campos["vDesc"].to_d,
                    campos["vFrete"].to_d, campos["vNF"].to_d, nota.total_amount.to_d)
      end

      sleep 0.4
    rescue StandardError => e
      falhas += 1

      puts "  ERRO  NF #{nota.number}: #{e.class} #{e.message.truncate(120)}"
    end

    puts "Regime tributário (CRT) nas notas lidas:"

    regimes.sort_by { |_, q| -q }.each do |crt, quantos|
      nome = { "1" => "Simples Nacional", "2" => "Simples, excesso de sublimite", "3" => "Regime Normal" }[crt]

      puts format("    CRT %-10s %3d nota(s)  %s", crt, quantos, nome)
    end

    puts
    puts "Situação tributária por item:"

    situacoes.sort_by { |_, q| -q }.first(12).each { |sit, quantos| puts format("    %-12s %d item(ns)", sit, quantos) }

    puts
    puts "Soma dos totais declarados nas #{notas.size - falhas} nota(s):"

    # Ordem de leitura contábil, não alfabética.
    ordem = %w[vProd vFrete vDesc vBC vICMS vBCST vST vIPI vPIS vCOFINS vOutro vNF]

    (ordem & totais.keys).each { |campo| puts format("    %-10s R$ %12.2f", campo, totais[campo]) }

    resto = totais.keys - ordem

    resto.each { |campo| puts format("    %-10s R$ %12.2f", campo, totais[campo]) }

    puts "    (falhas na leitura: #{falhas})" if falhas.positive?
    puts

    # ------------------------------------------------------------- o dinheiro

    puts "O que o marketplace retém, pelo relatório de liberações:"
    puts

    # `TAXES_AMOUNT` só existe nas linhas guardadas depois do reimporte com as
    # colunas novas. Sem ele, dizer "retenção zero" seria confundir ausência de
    # dado com ausência de imposto.
    com_linha = FinancialEntry
                  .where(tenant_id: tenant.id)
                  .where("jsonb_typeof(raw_payload) = 'object'")
                  .where("raw_payload ? 'TAXES_AMOUNT'")

    if com_linha.none?
      puts "  Nenhuma linha do relatório guardada ainda com TAXES_AMOUNT."
      puts "  Rode `rake marketplace:reimportar` para o período antes de concluir"
      puts "  qualquer coisa sobre retenção — vazio aqui é falta de dado, não de imposto."
    else
      soma = BigDecimal("0")
      nao_zero = 0
      fontes = {}

      com_linha.find_each do |lancamento|
        fonte = lancamento.raw_payload["SOURCE_ID"].to_s

        next if fonte.present? && fontes.key?(fonte)

        fontes[fonte] = true if fonte.present?

        valor = lancamento.raw_payload["TAXES_AMOUNT"].to_d

        soma += valor.abs

        nao_zero += 1 unless valor.zero?
      end

      puts format("  pagamentos com a coluna guardada: %d", fontes.size)
      puts format("  com TAXES_AMOUNT diferente de zero: %d", nao_zero)
      puts format("  soma retida: R$ %.2f", soma)
    end

    puts
    puts "Nada foi gravado."
  end
end
