namespace :conciliacao do
  desc "O mesmo pagamento entrou duas vezes? Recebíveis repetidos por pedido (SOMENTE LEITURA)"
  task recebiveis_repetidos: :environment do
    # No repasse #42 a NF 851156 tem DOIS recebíveis de R$ 230,65, ambos do pedido
    # 2000017361405266, contra uma nota de R$ 230,65. São R$ 230,65 num repasse
    # cuja diferença total é R$ 843,65 — 27% dela, e nada a ver com nota fiscal.
    #
    # Nem todo par é defeito: o Mercado Livre permite pagamento combinado (parte no
    # cartão, parte no saldo), e aí o MESMO pedido tem dois pagamentos cuja soma é
    # o valor da venda. O que denuncia duplicata é a soma EXCEDER o que a nota
    # documenta — dois de 230,65 para uma nota de 230,65.
    #
    # Por isso a saída separa: soma que cabe na nota (combinado, legítimo) de soma
    # que a excede (o mesmo dinheiro contado duas vezes).
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    # Pedidos com mais de um recebível. O `having` faz o filtro no banco: são
    # dezenas de milhares de recebíveis, e trazer todos para contar em Ruby é
    # diagnóstico que ninguém roda duas vezes.
    pedidos = ReceivableUnit
                .where(tenant_id: tenant.id)
                .where.not(order_id: nil)
                .group(:order_id)
                .having("COUNT(*) > 1")
                .count

    puts "Pedidos com mais de um recebível: #{pedidos.size}"
    puts

    if pedidos.empty?
      puts "Nenhum. O caso do #42 seria isolado."

      next
    end

    combinado = { casos: 0, valor: BigDecimal("0") }
    excede = { casos: 0, valor: BigDecimal("0") }
    sem_nota = { casos: 0, valor: BigDecimal("0") }

    exemplos = []

    ReceivableUnit
      .where(tenant_id: tenant.id, order_id: pedidos.keys)
      .includes(:order, :invoice)
      .group_by(&:order_id)
      .each do |_, lista|
        soma = lista.sum(BigDecimal("0")) { |u| u.gross_amount.to_d }

        nota = lista.filter_map(&:invoice).first

        if nota.blank?
          sem_nota[:casos] += 1
          sem_nota[:valor] += soma

          next
        end

        # `valor_produtos` e não o total: o total já tem frete somado e desconto
        # abatido, e é contra a mercadoria que o bruto da venda se compara.
        produtos = nota.metadata.to_h.dig("fiscal", "valor_produtos").to_d

        referencia = produtos.positive? ? produtos : nota.total_amount.to_d

        sobra = (soma - referencia).round(2)

        # Folga de 1 real: parcelamento somado ao bruto e arredondamento não são
        # duplicata, e um limite apertado transformaria ruído em alarme.
        if sobra > 1
          excede[:casos] += 1
          excede[:valor] += sobra

          exemplos << [ nota, lista, referencia, sobra ] if exemplos.size < 10
        else
          combinado[:casos] += 1
          combinado[:valor] += soma
        end
      end

    puts format("  soma CABE na nota (pagamento combinado, legítimo): %5d caso(s) · R$ %.2f",
                combinado[:casos], combinado[:valor])
    puts format("  soma EXCEDE a nota (mesmo dinheiro duas vezes):    %5d caso(s) · R$ %.2f de excesso",
                excede[:casos], excede[:valor])
    puts format("  sem nota para comparar:                            %5d caso(s) · R$ %.2f",
                sem_nota[:casos], sem_nota[:valor])
    puts

    if exemplos.any?
      puts "Os que excedem (até 10):"

      exemplos.each do |nota, lista, referencia, sobra|
        puts format("  NF %-10s produtos R$ %9.2f · %d recebíveis somando R$ %9.2f · excesso R$ %9.2f",
                    nota.number, referencia, lista.size,
                    lista.sum(BigDecimal("0")) { |u| u.gross_amount.to_d }, sobra)

        lista.each do |u|
          # O id do PAGAMENTO no external_id: se os dois forem iguais, nós
          # ingerimos a mesma linha duas vezes. Se forem diferentes, o
          # marketplace liberou dois pagamentos — e aí a pergunta é outra.
          puts format("      %-26s bruto R$ %9.2f · pedido %s · em repasse: %s",
                      u.external_id.to_s.truncate(26), u.gross_amount.to_d,
                      u.order&.external_id,
                      u.financial_entry_allocations.any? { |a| a.payout_batch_id.present? } ? "sim" : "não")
        end

        puts
      end
    end

    puts "Como ler:"
    puts "  external_id IGUAL nos dois -> ingerimos a mesma linha duas vezes, e o"
    puts "     conserto é nosso."
    puts "  external_id DIFERENTE -> o marketplace liberou dois pagamentos para o"
    puts "     mesmo pedido. Pode ser estorno e reemissão, e aí um dos dois deveria"
    puts "     ter saído do razão."
    puts
    puts "Nada foi gravado."
  end
end
