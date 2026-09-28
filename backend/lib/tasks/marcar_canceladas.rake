namespace :conciliacao do
  desc "Marca (sem apagar) os recebíveis de pedidos CANCELADOS no marketplace (APLICAR=1 grava)"
  task marcar_canceladas: :environment do
    # Medido em 2026-09-28, perguntando ao Mercado Livre o estado de cada pedido das 45
    # vendas sem nota dentro de repasse:
    #
    #   38  pedido CANCELADO e estornado   R$ 6.204,72   ← não são vendas
    #    3  sem pedido (aporte via PIX)    R$ 8.979,00   ← outra tarefa cuida
    #    4  pedido PAGO e aprovado         R$   658,60   ← estas SIM: venda sem nota
    #
    # Isso corrige a conclusão que eu tinha entregado como fechada — "42 vendas pagas sem
    # documento fiscal, exposição do cliente". São QUATRO, R$ 658,60. O resto é
    # cancelamento: não houve venda, então ninguém emitiu nota, e o ML responde 404 em
    # `/invoices/orders/<id>`. Todo mundo certo, menos o nosso razão, que segue contando
    # o recebível como venda paga dentro do repasse.
    #
    # NÃO apaga: marca, com o motivo e o estado que o marketplace informou.
    # `ReceivableUnit.vendas_reais` exclui nas duas pontas — bruto do repasse e
    # conciliação.
    #
    # Pergunta ao ML em vez de confiar no `status` do nosso pedido: ele fica em `pending`
    # enquanto o marketplace já diz `cancelled`, porque a ingestão grava o estado do
    # momento em que leu e ninguém volta para atualizar.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    aplicar = %w[true 1].include?(ENV["APLICAR"].to_s.strip.downcase)

    conta = PlatformAccount.find_by(tenant_id: tenant.id, platform: "mercado_livre", status: "active")

    abort "Nenhuma conta ativa do Mercado Livre." if conta.blank?

    puts aplicar ? "MODO: GRAVANDO (marca, não apaga)" : "MODO: SIMULAÇÃO"
    puts

    em_repasse = FinancialEntryAllocation
                   .where(tenant_id: tenant.id)
                   .where.not(payout_batch_id: nil)
                   .distinct
                   .pluck(:receivable_unit_id)
                   .compact

    alvos = ReceivableUnit
              .where(tenant_id: tenant.id, id: em_repasse, invoice_id: nil)
              .where.not(order_id: nil)
              .includes(:order)
              .to_a
              .reject(&:nao_e_venda?)

    puts "Vendas sem nota dentro de repasse, com pedido: #{alvos.size}"
    puts "Perguntando o estado de cada uma ao Mercado Livre..."
    puts

    client = Marketplace::MercadoLivre::OrdersClient.new(
      access_token: Marketplace::Credentials::TokenProvider.new(platform_account: conta).access_token,
      seller_id: conta.external_id
    )

    cancelados = []
    vivos = []
    sem_resposta = []

    alvos.each do |unidade|
      dados = client.order_raw(unidade.order.external_id)

      if dados.blank?
        sem_resposta << unidade

        next
      end

      # O ESTADO DO PAGAMENTO junto com o do pedido: pedido cancelado cujo pagamento
      # segue aprovado não é a mesma coisa, e marcar os dois igual esconderia o caso em
      # que o dinheiro ficou com o cliente.
      pagamentos = Array(dados["payments"]).map { |p| p["status"] }.uniq

      estornado = pagamentos.any? { |st| st.to_s.match?(/refunded|charged_back|cancelled/) }

      if dados["status"].to_s == "cancelled" && estornado
        cancelados << [ unidade, pagamentos.join("/") ]
      else
        vivos << [ unidade, "#{dados['status']} · #{pagamentos.join('/')}" ]
      end

      sleep 0.25
    rescue StandardError => e
      sem_resposta << unidade

      puts "  ERRO no pedido #{unidade.order&.external_id}: #{e.class} #{e.message}" if sem_resposta.size <= 3
    end

    soma = ->(lista) { lista.sum(BigDecimal("0")) { |u, _| u.gross_amount.to_d } }

    puts format("  cancelados E estornados: %4d · R$ %10.2f  <- a marcar", cancelados.size, soma.call(cancelados))
    puts format("  pedido vivo:             %4d · R$ %10.2f  <- venda real sem nota", vivos.size, soma.call(vivos))
    puts format("  sem resposta do ML:      %4d", sem_resposta.size)
    puts

    if vivos.any?
      puts "As que continuam valendo — estas são conversa com o cliente:"

      vivos.first(10).each do |unidade, estado|
        puts format("  pedido %-20s R$ %9.2f  %s", unidade.order.external_id, unidade.gross_amount.to_d, estado)
      end

      puts
    end

    next puts("Nada foi gravado. Use APLICAR=1 para marcar os cancelados.") unless aplicar

    marcados = 0

    ReceivableUnit.transaction do
      cancelados.each do |unidade, pagamentos|
        unidade.update!(metadata: (unidade.metadata || {}).merge(
          ReceivableUnit::MARCA_NAO_E_VENDA => {
            "descricao" => "pedido cancelado no marketplace",
            "motivo" => "pedido cancelled e pagamento #{pagamentos}: não houve venda",
            "marcado_em" => Time.current
          }
        ))

        marcados += 1
      end
    end

    puts "Marcados: #{marcados}"
    puts
    puts "Os recebíveis continuam no banco, com o motivo gravado. O bruto dos repasses"
    puts "afetados só muda depois de `conciliacao:recalcular_repasses TENANT=#{tenant.id} APLICAR=1`."
  end
end
