namespace :conciliacao do
  desc "O cupom do relatório e o desconto da nota são o mesmo dinheiro? (SOMENTE LEITURA)"
  task cupom_e_desconto: :environment do
    # A conciliação está descontando MAIS que a diferença em vários repasses: a
    # sobra fica negativa, o que só acontece quando duas parcelas contam o mesmo
    # dinheiro.
    #
    # Suspeita: `COUPON_AMOUNT`, que o Mercado Pago informa no relatório, e
    # `valor_desconto`, que a nota declara, são o MESMO desconto visto de dois
    # lados — o cupom concedido ao comprador sai como desconto no documento.
    #
    # Se forem, somar os dois é contar em dobro, e a conciliação está subtraindo
    # duas vezes o mesmo abatimento.
    #
    # Medido na base inteira, não num repasse: dois casos coincidentes não
    # decidem nada.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    unidades = ReceivableUnit
                 .where(tenant_id: tenant.id)
                 .where.not(invoice_id: nil)
                 .includes(:invoice)
                 .to_a

    abort "Nenhuma venda com nota." if unidades.none?

    linhas = FinancialEntry
               .where(tenant_id: tenant.id)
               .where("jsonb_typeof(raw_payload) = 'object'")
               .pluck(:external_id, :raw_payload)
               .to_h

    puts "Vendas com nota: #{unidades.size} · linhas do relatório guardadas: #{linhas.size}"
    puts

    caso = Hash.new(0)

    diferentes = []

    unidades.each do |unidade|
      cru = linhas[unidade.external_id]

      next caso[:sem_linha] += 1 if cru.blank?

      cupom = cru["COUPON_AMOUNT"].to_d.abs

      # O desconto é da NOTA. Uma nota de pacote cobre várias vendas, e cada uma
      # leria o mesmo desconto — por isso a comparação é por nota, adiante.
      desconto = unidade.invoice.metadata.to_h.dig("fiscal", "valor_desconto").to_d

      next caso[:sem_fiscal] += 1 if unidade.invoice.metadata.to_h["fiscal"].blank?

      if cupom.zero? && desconto.zero?
        caso[:ambos_zero] += 1
      elsif cupom.positive? && desconto.zero?
        caso[:so_cupom] += 1
      elsif cupom.zero? && desconto.positive?
        caso[:so_desconto] += 1
      elsif (cupom - desconto).abs < BigDecimal("0.01")
        caso[:iguais] += 1
      else
        caso[:diferentes] += 1

        if diferentes.size < 10
          diferentes << format("    NF %-10s cupom %8.2f · desconto %8.2f",
                               unidade.invoice.number, cupom, desconto)
        end
      end
    end

    puts "Comparando cupom do relatório com desconto da nota, venda a venda:"
    puts

    [
      [ :ambos_zero, "os dois zerados" ],
      [ :so_cupom, "só cupom, nota sem desconto" ],
      [ :so_desconto, "só desconto, relatório sem cupom" ],
      [ :iguais, "os dois positivos e IGUAIS" ],
      [ :diferentes, "os dois positivos e diferentes" ],
      [ :sem_linha, "sem a linha do relatório guardada" ],
      [ :sem_fiscal, "sem os dados fiscais da nota ainda" ]
    ].each do |chave, rotulo|
      puts format("  %-36s %d", rotulo, caso[chave]) if caso[chave].positive?
    end

    puts

    puts diferentes if diferentes.any?

    puts if diferentes.any?

    puts "Como ler:"
    puts "  muitos IGUAIS e quase nenhum só-cupom      -> é o mesmo dinheiro;"
    puts "     somar os dois na conciliação conta em dobro."
    puts "  muitos só-cupom e muitos só-desconto        -> são coisas diferentes,"
    puts "     e a soma está certa; a sobra negativa vem de outro lugar."
    puts
    puts "Nada foi gravado."
  end
end
