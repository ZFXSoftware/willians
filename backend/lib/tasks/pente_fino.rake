namespace :conciliacao do
  desc "Nota por nota, nos 35 repasses: onde cada diferença nasce (SOMENTE LEITURA)"
  task pente_fino: :environment do
    # "Um repasse conciliou — posso confiar nos outros?" A resposta honesta é que o
    # TRATAMENTO é idêntico (mesmo código, mesmas regras, mesma ordem de hipóteses) e os
    # DADOS não são. O que fechou fechou porque todas as notas dele couberam nas
    # hipóteses nomeadas.
    #
    # Então em vez de opinião, a lista: por repasse, quantas notas fecham ao centavo e o
    # que sobra COM NOME. Usa `ComposicaoDaVenda`, a mesma classe que o motor usa — sonda
    # que refaz a conta mede a suposição de quem a escreveu, e isso já me custou dois
    # falsos achados nesta base.
    #
    # Uma leitura do OMIE para todos os repasses: pedir por repasse renderia 35
    # requisições idênticas e o bloqueio por consumo redundante.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    lotes = PayoutBatch.where(tenant_id: tenant.id).order(:paid_at).to_a

    next puts("Nenhum repasse.") if lotes.empty?

    puts "Lendo os títulos do OMIE uma vez (pode esperar o desbloqueio)..."

    leitor = Omie::Readers::ReceivableTotals.new(client: Omie::Client.new(tenant: tenant))

    titulos = Current.with_tenant(tenant) do
      leitor.call(start_date: lotes.first.paid_at.to_date - 120, end_date: Date.current)
    end

    puts

    registros = ConciliacaoRegistro
                  .where(id: ConciliacaoRegistro.ids_dos_ultimos(tenant.id))
                  .index_by(&:payout_batch_id)

    causas = Hash.new { |h, k| h[k] = { notas: 0, valor: BigDecimal("0"), repasses: Set.new } }

    limpos = []

    sujos = []

    puts format("  %-6s %-12s %6s %7s %7s %12s %12s",
                "id", "pago em", "notas", "fecham", "sobram", "soma deltas", "diferença")

    lotes.each do |lote|
      unidades = lote.financial_entry_allocations
                     .filter_map(&:receivable_unit)
                     .uniq
                     .reject(&:nao_e_venda?)

      por_nota = unidades.select(&:invoice).group_by(&:invoice)

      next if por_nota.empty?

      linhas = FinancialEntry
                 .where(tenant_id: tenant.id, external_id: unidades.map(&:external_id))
                 .pluck(:external_id, :raw_payload)
                 .to_h { |externo, cru| [ externo, cru.is_a?(Hash) ? cru : {} ] }

      totais_da_nota = ReceivableUnit
                         .where(tenant_id: tenant.id, invoice_id: por_nota.keys.map(&:id))
                         .group(:invoice_id)
                         .sum(:gross_amount)

      fecham = 0
      soma_delta = BigDecimal("0")

      por_nota.each do |nota, vendas|
        chave = Omie::Readers::ReceivableTotals.normalizar(nota.number)

        titulo = titulos[chave]

        bruto_total = totais_da_nota[nota.id].to_d

        bruto_aqui = vendas.sum(BigDecimal("0")) { |u| u.gross_amount.to_d }

        fracao = bruto_total.positive? ? (bruto_aqui / bruto_total) : BigDecimal("1")

        composicao = Conciliacao::ComposicaoDaVenda.para(
          nota: nota, vendas: vendas, linhas: linhas, fracao: fracao
        )

        if titulo.blank?
          causas["nota sem título no OMIE"][:notas] += 1
          causas["nota sem título no OMIE"][:valor] += nota.total_amount.to_d
          causas["nota sem título no OMIE"][:repasses] << lote.id

          next
        end

        delta = composicao.delta_para(titulo, fracao)

        soma_delta += delta

        if delta.abs <= BigDecimal("0.01")
          fecham += 1

          next
        end

        # A causa com NOME. `titulo ≈ 2 × nota` é duplicata no OMIE — e a auditoria já
        # achou três; aqui ela aparece ligada ao repasse que paga o preço.
        nome =
          if (titulo - (nota.total_amount.to_d * 2)).abs <= BigDecimal("0.02")
            "título DUPLICADO no OMIE"
          elsif composicao.produtos.zero?
            "nota sem valor_produtos"
          elsif composicao.hipotese == :sobra_sem_hipotese
            "sobra sem hipótese (bruto > produtos)"
          elsif fracao < 1
            "nota de pacote: rateio"
          else
            "delta sem causa nomeada"
          end

        causas[nome][:notas] += 1
        causas[nome][:valor] += delta.abs
        causas[nome][:repasses] << lote.id
      end

      sobram = por_nota.size - fecham

      registro = registros[lote.id]

      puts format("  #%-5d %-12s %6d %7d %7d %12.2f %12s",
                  lote.id, lote.paid_at&.to_date, por_nota.size, fecham, sobram,
                  soma_delta, registro ? format("%.2f", registro.diferenca.to_d) : "—")

      (sobram.zero? ? limpos : sujos) << lote.id
    end

    puts
    puts format("Repasses com TODAS as notas fechando ao centavo: %d de %d", limpos.size, lotes.size)
    puts "  ids: #{limpos.sort.join(', ')}" if limpos.any?
    puts format("Repasses com nota sobrando: %d", sujos.size)
    puts

    puts "As causas, por tamanho:"
    causas.sort_by { |_, c| -c[:valor] }.each do |nome, c|
      puts format("  %-40s %5d nota(s) · R$ %11.2f · em %d repasse(s)",
                  nome, c[:notas], c[:valor], c[:repasses].size)
    end

    puts
    puts "Como ler:"
    puts "  repasse LIMPO com diferença != 0 -> a diferença não está nas notas: é venda"
    puts "     sem nota, recebível que não é venda, ou o bruto gravado do repasse."
    puts "  `título DUPLICADO` -> conserto no OMIE, e é decisão do cliente."
    puts "  `sobra sem hipótese` -> o bruto traz algo que nem frete nem parcelamento"
    puts "     explicam. É o que ainda não tem nome, e o próximo a investigar."
    puts
    puts "Nada foi gravado."
  end
end
