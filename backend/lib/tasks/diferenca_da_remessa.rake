# O mesmo valor que o motor compara: bruto quando existe, líquido como reserva.
# `total_amount` não existe em PayoutBatch — eu inventei a coluna.
def valor_de(lote)
  (lote.gross_amount || lote.net_amount).to_d
end

namespace :conciliacao do
  desc "De onde vem a diferença que sobrou num repasse, venda a venda (SOMENTE LEITURA)"
  task diferenca_da_remessa: :environment do
    # A diferença que sobrou depois de descontar vendas sem nota é pequena — R$
    # 37 em R$ 11 mil — e pequena é justamente o tamanho de um desconto: cupom
    # do vendedor, frete, ajuste. A hipótese é testável sem chamar API nenhuma:
    # se as diferenças venda a venda somarem o resíduo, a causa está nelas.
    #
    # E se NÃO somarem, a causa é outra e a hipótese morre aqui — que é o
    # desfecho que este relatório existe para permitir.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    lote = PayoutBatch.find_by(tenant_id: tenant.id, id: ENV["REPASSE"])

    if lote.blank?
      puts "Diga qual repasse com REPASSE=<id>. Os últimos:"

      PayoutBatch.where(tenant_id: tenant.id).order(paid_at: :desc).limit(10).each do |candidato|
        puts format("  ##{candidato.id}  ref %-24s pago em %s  R$ %.2f",
                    candidato.external_id.to_s[0, 24], candidato.paid_at, valor_de(candidato))
      end

      next
    end

    unidades = lote.financial_entry_allocations.filter_map(&:receivable_unit).uniq

    puts "Repasse ##{lote.id} · pago em #{lote.paid_at} · R$ #{format('%.2f', valor_de(lote))}"
    puts "#{unidades.size} venda(s) penduradas."
    puts

    com_nota = unidades.select(&:invoice_id)

    puts "Vendas com nota: #{com_nota.size} (as sem nota já têm relatório próprio)."
    puts

    # A nota do PACOTE vale por várias vendas: compará-la inteira contra UMA
    # delas inventaria uma diferença que não existe.
    por_nota = com_nota.group_by(&:invoice_id)

    linhas = []

    soma_venda = BigDecimal("0")
    soma_nota = BigDecimal("0")

    por_nota.each do |invoice_id, lista|
      nota = lista.first.invoice

      venda = lista.sum { |unidade| unidade.gross_amount.to_d }

      valor_nota = nota.total_amount.to_d

      soma_venda += venda
      soma_nota += valor_nota

      diferenca = venda - valor_nota

      next if diferenca.abs < BigDecimal("0.01")

      linhas << {
        nota: nota,
        pedidos: lista.map { |unidade| unidade.order&.external_id }.compact,
        vendas: lista.size,
        venda: venda,
        valor_nota: valor_nota,
        diferenca: diferenca
      }
    end

    puts format("Soma das vendas (ML):  R$ %.2f", soma_venda)
    puts format("Soma das notas (NF):   R$ %.2f", soma_nota)
    puts format("Diferença total:       R$ %.2f", soma_venda - soma_nota)
    puts

    if linhas.none?
      puts "Nenhuma venda com nota difere da nota. A diferença do repasse NÃO vem daqui —"
      puts "vem das vendas sem nota, das taxas, ou do agrupamento."

      next
    end

    puts "#{linhas.size} nota(s) com valor diferente da venda, da maior para a menor:"
    puts

    puts format("  %-10s %-6s %12s %12s %12s  %s", "NF", "vendas", "venda (ML)", "nota (NF)", "diferença", "pedido")

    linhas.sort_by { |linha| -linha[:diferenca].abs }.first(25).each do |linha|
      puts format("  %-10s %-6d %12.2f %12.2f %12.2f  %s",
                  linha[:nota].number, linha[:vendas], linha[:venda], linha[:valor_nota],
                  linha[:diferenca], linha[:pedidos].first.to_s[0, 20])
    end

    puts "  ... (#{linhas.size - 25} outras)" if linhas.size > 25
    puts

    maiores = linhas.count { |linha| linha[:diferenca].positive? }

    puts format("Soma das diferenças:   R$ %.2f", linhas.sum { |linha| linha[:diferenca] })
    puts "  vendas MAIORES que a nota: #{maiores}   <- desconto dado depois da emissão (cupom do vendedor, ajuste)"
    puts "  vendas MENORES que a nota: #{linhas.size - maiores}   <- nota emitida por valor maior (frete embutido?)"
    puts
    puts "Como ler: se esta soma bate com a diferença que sobrou na conciliação, a"
    puts "causa é esta. Se não bate, é outra coisa — e a hipótese cai."
    puts
    puts "Nada foi gravado."
  end
end
