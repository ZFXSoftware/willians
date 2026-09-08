# Fechados num módulo porque `def` no topo de um .rake define em Object: todos
# os arquivos de tarefa dividem o mesmo espaço, e `tiny.rake` já tinha um
# `valores_de` de um argumento. O que carrega por último vence, e as 45
# conferências morreram em "wrong number of arguments" — erro que aparece só na
# VPS, com os dois arquivos carregados juntos.
module DiferencaDaRemessa
  module_function

  # O mesmo valor que o motor compara: bruto quando existe, líquido como
  # reserva. `total_amount` não existe em PayoutBatch — eu inventei a coluna.
  def valor_de(lote)
    (lote.gross_amount || lote.net_amount).to_d
  end

  # Pergunta ao Mercado Livre o cupom de cada venda que difere da nota.
  #
  # Medido em dois pedidos: a diferença é exatamente `coupon_amount` somado sobre
  # os pagamentos, e o relatório de liberações credita o valor CHEIO — ou seja, o
  # cupom é bancado pelo marketplace, o vendedor recebe tudo, e é a nota que sai
  # menor. Dois casos não fazem uma regra; isto confere o repasse inteiro.
  def conferir_cupons(conta, linhas)
    return puts("  (sem conta de marketplace nas vendas; pulei a conferência de cupons.)") if conta.blank?

    client = Marketplace::MercadoLivre::OrdersClient.new(
      access_token: Marketplace::Credentials::TokenProvider.new(platform_account: conta).access_token,
      seller_id: conta.external_id
    )

    puts "Conferindo o cupom de cada uma no Mercado Livre:"
    puts

    explicadas = 0
    por_frete = 0
    soma_cupom = BigDecimal("0")
    sobrando = []

    linhas.each do |linha|
      # `uniq` porque um pedido pago em DUAS parcelas vira duas vendas, e o mesmo
      # pedido aparecia duas vezes aqui — somando o cupom em dobro e inventando
      # uma sobra negativa exatamente do tamanho do cupom.
      dinheiro = linha[:pedidos].uniq.map { |externo| valores_de(client, externo) }

      cupom = dinheiro.sum(BigDecimal("0")) { |v| v[:cupom] }

      frete = dinheiro.sum(BigDecimal("0")) { |v| v[:frete] }

      soma_cupom += cupom

      if (linha[:diferenca] - cupom).abs < BigDecimal("0.01")
        explicadas += 1
      elsif (linha[:diferenca] - cupom - frete).abs < BigDecimal("0.01")
        por_frete += 1
      else
        sobrando << format("    NF %-10s dif %8.2f · cupom %7.2f · frete %7.2f · itens %8.2f · pago %8.2f · sobra %8.2f",
                           linha[:nota].number, linha[:diferenca], cupom, frete,
                           dinheiro.sum(BigDecimal("0")) { |v| v[:itens] },
                           dinheiro.sum(BigDecimal("0")) { |v| v[:pago] },
                           linha[:diferenca] - cupom - frete)
      end

      sleep 0.3
    rescue StandardError => e
      sobrando << "    NF #{linha[:nota].number}: #{e.class} #{e.message}"
    end

    puts format("  explicadas só pelo cupom:             %d de %d", explicadas, linhas.size)
    puts format("  explicadas por cupom + frete:         %d", por_frete)
    puts format("  soma dos cupons:                      R$ %.2f", soma_cupom)
    puts

    if sobrando.any?
      puts "  Não explicadas pelo cupom:"

      puts sobrando.first(10)

      puts
    end
  end

  # Os quatro valores que podem explicar a diferença, do pedido bruto.
  #
  # Imprimir a composição inteira em vez de testar uma hipótese por vez: eu já
  # concluí "é cupom" de dois pedidos, e o cupom explicava menos da metade.
  def valores_de(client, externo)
    bruto = client.bruto("/orders/#{externo}")

    pagamentos = Array(bruto["payments"])

    {
      cupom: pagamentos.sum(BigDecimal("0")) { |p| p["coupon_amount"].to_d },
      frete: pagamentos.sum(BigDecimal("0")) { |p| p["shipping_cost"].to_d },
      pago: pagamentos.sum(BigDecimal("0")) { |p| p["transaction_amount"].to_d },
      itens: Array(bruto["order_items"]).sum(BigDecimal("0")) do |item|
        item["unit_price"].to_d * item["quantity"].to_i
      end
    }
  end

  # Compara cada NOTA com a soma das vendas que ela cobre.
  #
  # Agrupar por nota antes de comparar é obrigatório: a nota do PACOTE vale por
  # várias vendas, e confrontá-la inteira contra uma delas inventaria uma
  # diferença do tamanho das outras.
  def diferencas_por_nota(com_nota)
    com_nota.group_by(&:invoice_id).filter_map do |_, lista|
      nota = lista.first.invoice

      venda = lista.sum(BigDecimal("0")) { |unidade| unidade.gross_amount.to_d }

      diferenca = venda - nota.total_amount.to_d

      next if diferenca.abs < BigDecimal("0.01")

      {
        nota: nota,
        pedidos: lista.filter_map { |unidade| unidade.order&.external_id },
        vendas: lista.size,
        venda: venda,
        valor_nota: nota.total_amount.to_d,
        diferenca: diferenca
      }
    end
  end
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
      # Varre todos em vez de pedir para escolher no escuro: o resíduo que a
      # gente persegue está em três repasses, e ninguém sabe quais.
      puts "Sem REPASSE=<id>: uma linha por repasse, para achar onde a diferença mora."
      puts

      puts format("  %-5s %-12s %10s %10s %8s %12s",
                  "id", "pago em", "vendas", "c/ nota", "diferem", "soma dif.")

      PayoutBatch.where(tenant_id: tenant.id).order(paid_at: :desc).limit(30).each do |candidato|
        unidades = candidato.financial_entry_allocations.filter_map(&:receivable_unit).uniq

        com_nota = unidades.select(&:invoice_id)

        divergentes = DiferencaDaRemessa.diferencas_por_nota(com_nota)

        puts format("  #%-4d %-12s %10d %10d %8d %12.2f",
                    candidato.id, candidato.paid_at&.to_date, unidades.size, com_nota.size,
                    divergentes.size, divergentes.sum { |linha| linha[:diferenca] })
      end

      puts
      puts "Depois abra o que interessar com REPASSE=<id>."

      next
    end

    unidades = lote.financial_entry_allocations.filter_map(&:receivable_unit).uniq

    puts "Repasse ##{lote.id} · pago em #{lote.paid_at} · R$ #{format('%.2f', DiferencaDaRemessa.valor_de(lote))}"
    puts "#{unidades.size} venda(s) penduradas."
    puts

    com_nota = unidades.select(&:invoice_id)

    puts "Vendas com nota: #{com_nota.size} (as sem nota já têm relatório próprio)."
    puts

    linhas = DiferencaDaRemessa.diferencas_por_nota(com_nota)

    soma_venda = com_nota.sum(BigDecimal("0")) { |unidade| unidade.gross_amount.to_d }

    soma_nota = com_nota.map(&:invoice).uniq.sum(BigDecimal("0")) { |nota| nota.total_amount.to_d }

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

    # A conta sai das PRÓPRIAS vendas do repasse, e não de uma busca por
    # plataforma: adivinhar qual conta usar é como este projeto já escolheu a
    # empresa errada quatro vezes.
    if ENV["COM_ML"] == "1"
      DiferencaDaRemessa.conferir_cupons(PlatformAccount.find_by(id: com_nota.first&.platform_account_id), linhas)
    end

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
