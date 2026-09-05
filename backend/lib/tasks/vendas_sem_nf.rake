namespace :conciliacao do
  desc "Das vendas já pagas pelo marketplace, quantas têm nota fiscal — e por que as outras não (SOMENTE LEITURA)"
  task vendas_sem_nf: :environment do
    # "Não tem NF" esconde três situações com consertos completamente
    # diferentes, e na tela as três aparecem iguais:
    #
    #   1. a nota ESTÁ no nosso banco e não foi ligada ao recebível
    #      -> defeito de vínculo, conserto nosso e imediato
    #   2. a nota não está no nosso banco
    #      -> defeito de importação: a janela do Tiny não alcançou aquela data
    #   3. a nota não existe nem no Tiny
    #      -> o cliente não emitiu, e aí não é problema de software
    #
    # Sem separar, a pergunta "temos as NF das vendas pagas?" não tem resposta.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    recebiveis = ReceivableUnit.where(tenant_id: tenant.id)

    total = recebiveis.count

    com_nota = recebiveis.where.not(invoice_id: nil).count

    puts "Vendas (recebíveis) no banco: #{total}"
    puts format("  com nota fiscal ligada:  %d (%.1f%%)", com_nota, porcento(com_nota, total))
    puts format("  sem nota fiscal ligada:  %d", total - com_nota)
    puts

    sem_nota = recebiveis.where(invoice_id: nil).includes(:order)

    if sem_nota.none?
      puts "Todas as vendas têm nota. Nada a investigar aqui."

      next
    end

    # A nota pode existir e só não ter sido ligada. O elo é o número do pedido:
    # `numero_ecommerce` na nota, `external_id` no pedido.
    referencias = sem_nota.filter_map { |unidade| unidade.order&.external_id }.uniq

    # Separadas de propósito: nota CANCELADA está no banco e não deve ser
    # religada. O ciclo a solta da venda justamente porque ela não vale mais, e
    # contá-la como "órfã" manda reimportar o Tiny para desfazer o conserto.
    #
    # Venda cuja nota foi cancelada não precisa de vínculo: precisa de OUTRA
    # nota.
    escopo_notas = Invoice
                     .where(tenant_id: tenant.id)
                     .where("invoices.metadata->>'numero_ecommerce' IN (?)", referencias.presence || [ "" ])

    notas_por_pedido =
      escopo_notas
        .where.not(status: :cancelled)
        .pluck(Arel.sql("invoices.metadata->>'numero_ecommerce'"), :number)
        .to_h

    canceladas_por_pedido =
      escopo_notas
        .where(status: :cancelled)
        .pluck(Arel.sql("invoices.metadata->>'numero_ecommerce'"), :number)
        .to_h

    orfas = 0
    ausentes = 0
    sem_pedido = 0
    canceladas = 0

    exemplos = { orfa: [], ausente: [], cancelada: [] }

    sem_nota.find_each do |unidade|
      referencia = unidade.order&.external_id

      if referencia.blank?
        sem_pedido += 1

        next
      end

      if notas_por_pedido.key?(referencia)
        orfas += 1

        exemplos[:orfa] << "#{referencia} (NF #{notas_por_pedido[referencia]})" if exemplos[:orfa].size < 5
      elsif canceladas_por_pedido.key?(referencia)
        canceladas += 1

        if exemplos[:cancelada].size < 5
          exemplos[:cancelada] << "#{referencia} (NF #{canceladas_por_pedido[referencia]} cancelada)"
        end
      else
        ausentes += 1

        exemplos[:ausente] << "#{referencia} liberado em #{unidade.expected_on}" if exemplos[:ausente].size < 5
      end
    end

    # Onde a corrente do PACOTE está parando.
    #
    # A nota do pacote só encontra a venda se o pedido carregar o `pack_id`, e
    # quem grava isso é a sincronização com o Mercado Livre. Sem esse número, o
    # religamento por pacote não tem por onde começar — e "543 sem nota"
    # continua igual sem dizer que o problema é anterior.
    pedidos_ml = Order.where(tenant_id: tenant.id, platform: "mercado_livre")

    com_pack = pedidos_ml.where("orders.metadata->>'pack_id' IS NOT NULL").count

    da_api = pedidos_ml.where("orders.metadata->>'origem' IS DISTINCT FROM 'tiny_invoice_sync'").count

    puts "Pedidos do Mercado Livre: #{pedidos_ml.count}"
    puts "  vindos da API do marketplace:  #{da_api}"
    puts "  com pack_id gravado:           #{com_pack}"

    if com_pack.zero?
      puts
      puts "  NENHUM pedido tem pack_id. O religamento por pacote não roda sem ele,"
      puts "  e quem o grava é a sincronização com o Mercado Livre (VinculoDePedidos)."
      puts "  Confira se a ingestão está rodando e se o token do ML está válido."
    end

    puts

    puts "Por que a nota não está ligada:"
    puts
    puts format("  %-46s %d", "a nota ESTÁ no nosso banco, sem vínculo", orfas)
    puts format("  %-46s %d", "a nota foi CANCELADA (precisa de outra)", canceladas)
    puts format("  %-46s %d", "a nota não está no nosso banco", ausentes)
    puts format("  %-46s %d", "o recebível não tem pedido", sem_pedido)
    puts

    exemplos[:orfa].each { |exemplo| puts "    órfã:     #{exemplo}" }
    exemplos[:cancelada].each { |exemplo| puts "    cancelada: #{exemplo}" }
    exemplos[:ausente].each { |exemplo| puts "    faltando: #{exemplo}" }

    puts

    if ausentes.positive?
      datas = sem_nota.filter_map(&:expected_on)

      puts format("  As vendas sem nota vão de %s a %s.", datas.min, datas.max) if datas.any?

      janela = Invoice.where(tenant_id: tenant.id).minimum(:issued_at)

      puts "  A nota mais antiga que importamos é de #{janela&.to_date || '—'}."
      puts "  Se as vendas sem nota são anteriores a isso, o problema é a janela"
      puts "  da importação do Tiny, e não a emissão."
    end

    puts
    puts "Como consertar:"
    puts "  órfãs      -> reimportar do Tiny cobrindo a data delas religa o vínculo."
    puts "  canceladas -> a venda precisa de OUTRA nota. Religar a cancelada"
    puts "                desfaria o conserto: ela não vira título no OMIE."
    puts "  faltando   -> importar o Tiny com janela maior (DIAS)."
    puts "  sem pedido -> o recebível não achou o pedido no marketplace."
    puts
    puts "Nada foi gravado."
  end

  def porcento(parte, total)
    return 0.0 if total.to_i.zero?

    parte * 100.0 / total
  end
end
