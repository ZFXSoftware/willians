namespace :ml do
  desc "Os valores que o Mercado Livre guarda de um pedido, para nomear o desconto (SOMENTE LEITURA)"
  task valores_do_pedido: :environment do
    # O padrão nos repasses é desconto de valor FIXO — R$ 4,00 oito vezes, R$
    # 10,00 três vezes, com a nota sempre menor que a venda. Falta o nome:
    # cupom do vendedor, cupom do marketplace, custo fixo por venda ou frete
    # mudam quem paga a conta e o que a conciliação deve comparar.
    #
    # Só o pedido bruto diz. Este relatório imprime os campos de DINHEIRO e
    # nada mais: nome, endereço e documento do comprador não têm por que passar
    # por um terminal.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    externo = ENV["PEDIDO"].to_s.strip

    abort "Diga qual pedido com PEDIDO=<id do marketplace>." if externo.blank?

    pedido = Order.find_by(tenant_id: tenant.id, external_id: externo)

    abort "Pedido #{externo} não está no nosso banco." if pedido.blank?

    conta = PlatformAccount.find_by(id: pedido.platform_account_id)

    abort "Pedido sem conta de marketplace." if conta.blank?

    client = Marketplace::MercadoLivre::OrdersClient.new(
      access_token: Marketplace::Credentials::TokenProvider.new(platform_account: conta).access_token,
      seller_id: conta.external_id
    )

    bruto = client.bruto("/orders/#{externo}")

    # TODAS as unidades do pedido, não a primeira: um pedido pago em dois
    # pagamentos vira duas vendas, e mostrar só uma faz a venda parecer R$ 8,43
    # quando ela é R$ 129,65 — número errado bem no relatório que existe para
    # explicar números.
    unidades = ReceivableUnit.where(tenant_id: tenant.id, order_id: pedido.id).to_a

    nota = unidades.filter_map(&:invoice).first

    puts "Pedido #{externo}"
    puts format("  no nosso banco: venda R$ %.2f em %d parte(s) · nota %s R$ %.2f",
                unidades.sum(BigDecimal("0")) { |u| u.gross_amount.to_d }, unidades.size,
                nota&.number || "(sem)", nota&.total_amount.to_d)
    puts

    puts "O que o Mercado Livre guarda:"
    puts format("  total_amount (soma dos itens):   %s", bruto["total_amount"])
    puts format("  paid_amount (o que foi pago):    %s", bruto["paid_amount"])
    puts format("  coupon:                          %s", bruto["coupon"].inspect)
    puts format("  shipping_cost:                   %s", bruto["shipping_cost"].inspect)
    puts

    puts "Itens (preço cheio x preço cobrado):"

    Array(bruto["order_items"]).each do |item|
      puts format("  qtd %-3s  full_unit_price %-10s unit_price %-10s  sale_fee %s",
                  item["quantity"], item["full_unit_price"], item["unit_price"], item["sale_fee"])
    end

    puts

    puts "Pagamentos:"

    Array(bruto["payments"]).each do |pagamento|
      puts format("  %s  transaction %-10s shipping %-8s fee %-8s coupon %-8s status %s",
                  pagamento["id"], pagamento["transaction_amount"],
                  pagamento["shipping_cost"], pagamento["marketplace_fee"],
                  pagamento["coupon_amount"], pagamento["status"])
    end

    puts
    puts "Como ler:"
    puts "  coupon_amount no PAGAMENTO       -> o marketplace bancou; a venda não muda para o vendedor."
    puts "  full_unit_price > unit_price     -> o VENDEDOR baixou o preço; a nota está certa e o"
    puts "                                      nosso gross_amount é que guardou o preço de tabela."
    puts "  shipping_cost                    -> frete, e a comparação precisa separá-lo dos dois lados."
    puts
    puts "Nada foi gravado."
  end
end
