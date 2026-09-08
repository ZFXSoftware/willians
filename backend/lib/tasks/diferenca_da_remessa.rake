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

  # A diferença é a COMISSÃO?
  #
  # Medido num pedido: a nota bate exato com o valor do pedido no ML, e o nosso
  # bruto é o pedido MAIS a comissão. Se fosse regra geral, porém, toda venda
  # divergiria — e no repasse #19 só 45 de 184 divergem. Ou o relatório manda a
  # linha em dois formatos, ou há outra coisa separando os dois grupos, e é
  # isso que esta conta mostra sem chamar API nenhuma.
  def comparar_com_a_taxa(com_nota, linhas)
    divergentes = linhas.map { |linha| linha[:nota].id }.to_set

    iguais = com_nota.reject { |unidade| divergentes.include?(unidade.invoice_id) }

    puts "Comparando a diferença com a COMISSÃO cobrada em cada venda:"
    puts

    perto = 0

    linhas.each do |linha|
      taxa = com_nota.select { |u| u.invoice_id == linha[:nota].id }
                     .sum(BigDecimal("0")) { |u| u.fee_amount.to_d }

      perto += 1 if (linha[:diferenca] - taxa).abs <= BigDecimal("1.00")
    end

    puts format("  divergentes cuja diferença é ~a comissão (±R$1): %d de %d", perto, linhas.size)
    puts

    # O outro grupo é o que decide: se as que NÃO divergem também têm comissão,
    # então o bruto não inclui a comissão sempre — e a explicação é parcial.
    com_taxa = iguais.count { |unidade| unidade.fee_amount.to_d.positive? }

    puts format("  vendas que NÃO divergem: %d, das quais %d têm comissão cobrada",
                iguais.size, com_taxa)
    puts

    if com_taxa.positive?
      puts "  Ou seja: existe venda com comissão cujo bruto JÁ bate com a nota."
      puts "  O bruto não inclui a comissão sempre — as duas populações vêm do"
      puts "  mesmo relatório com formatos diferentes, e é isso que falta nomear."
    else
      puts "  Nenhuma venda sem divergência tem comissão: as duas coisas andam juntas,"
      puts "  e o bruto inflado pela comissão explica a diferença inteira."
    end

    puts
  end

  # O que separa as vendas que divergem das que não divergem?
  #
  # A linha do relatório traz PAYMENT_METHOD_TYPE e as datas de aprovação e de
  # liberação. Se as divergentes forem compras PARCELADAS e as iguais à vista,
  # o valor a mais é juro do comprador — que o Mercado Livre soma no bruto e a
  # nota fiscal, corretamente, não documenta.
  #
  # Compara as duas populações em vez de olhar só as divergentes: foi olhando
  # só um lado que eu fechei quatro explicações erradas seguidas.
  def separar_por_forma_de_pagamento(tenant, com_nota, linhas)
    divergentes = linhas.map { |linha| linha[:nota].id }.to_set

    grupos = com_nota.group_by { |unidade| divergentes.include?(unidade.invoice_id) ? :diferem : :iguais }

    puts "Forma de pagamento das duas populações:"
    puts

    grupos.each do |rotulo, unidades|
      contagem = Hash.new(0)

      dias = []

      unidades.each do |unidade|
        cru = linha_do_relatorio(tenant, unidade)

        next contagem["(sem a linha guardada)"] += 1 if cru.blank?

        contagem[cru["PAYMENT_METHOD_TYPE"].presence || "(vazio)"] += 1

        aprovado = cru["TRANSACTION_APPROVAL_DATE"]
        liberado = cru["DATE"]

        dias << (Date.parse(liberado) - Date.parse(aprovado)).to_i if aprovado.present? && liberado.present?
      end

      puts "  #{rotulo} (#{unidades.size}):"

      contagem.sort_by { |_, quantas| -quantas }.each do |forma, quantas|
        puts format("    %-24s %d", forma, quantas)
      end

      if dias.any?
        puts format("    dias entre aprovação e liberação: mínimo %d, mediana %d, máximo %d",
                    dias.min, dias.sort[dias.size / 2], dias.max)
      end

      puts
    end

    puts "  Se as que DIFEREM forem de um tipo e as IGUAIS de outro, o tipo é a causa."
    puts
  end

  # A linha do relatório que deu origem à venda. Guardada desde o reimporte —
  # antes disso não existe e a comparação não tem o que dizer.
  def linha_do_relatorio(tenant, unidade)
    entrada = FinancialEntry.find_by(tenant_id: tenant.id, external_id: unidade.external_id)

    cru = entrada&.raw_payload

    cru = (JSON.parse(cru) rescue nil) if cru.is_a?(String)

    cru.is_a?(Hash) ? cru : nil
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

    DiferencaDaRemessa.comparar_com_a_taxa(com_nota, linhas)

    DiferencaDaRemessa.separar_por_forma_de_pagamento(tenant, com_nota, linhas)

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
