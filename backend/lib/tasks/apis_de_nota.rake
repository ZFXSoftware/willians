namespace :ml do
  desc "Quais endpoints fiscais do Mercado Livre respondem, para uma venda (SOMENTE LEITURA)"
  task apis_de_nota: :environment do
    # Provado nesta sessão: as 232 notas que faltam existem, são do CNPJ do
    # cliente, têm chave válida, e o Tiny não as tem — elas caem nos buracos da
    # numeração dele. Outro emissor gravou na mesma série, e o candidato é a
    # emissão do próprio Mercado Livre.
    #
    # A documentação diz que dá para obter nota fiscal por invoice_id, order_id e
    # shipment_id, baixar XML e DANFE, e baixar em lote por período. Não diz os
    # caminhos completos numa página que eu consiga ler, então em vez de chutar um
    # endpoint e concluir do erro, isto TENTA os candidatos e imprime o que cada
    # um responde.
    #
    # NÃO imprime o conteúdo do XML: ele carrega nome e CPF do comprador. Só
    # status, tipo, tamanho, se parece NF-e, e a chave de acesso.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    conta = PlatformAccount.find_by(tenant_id: tenant.id, platform: "mercado_livre", status: "active")

    abort "Nenhuma conta ativa do Mercado Livre." if conta.blank?

    externo = ENV["PEDIDO"].to_s.strip

    if externo.blank?
      # Uma das que faltam, sorteada: é sobre elas que a pergunta é.
      pedido = Order
                 .where(tenant_id: tenant.id)
                 .where("jsonb_typeof(orders.metadata->'nota_do_envio') = 'object'")
                 .order(Arel.sql("RANDOM()"))
                 .first

      abort "Nenhum pedido com nota do marketplace guardada." if pedido.blank?

      externo = pedido.external_id
    else
      pedido = Order.find_by(tenant_id: tenant.id, external_id: externo)
    end

    dados = pedido&.metadata&.dig("nota_do_envio") || {}

    puts "Pedido #{externo}"
    puts "  o marketplace diz: NF #{dados['numero']}/#{dados['serie']} de #{dados['data'].to_s.first(10)}"
    puts "  chave: ...#{dados['chave'].to_s.last(8)}"
    puts

    client = Marketplace::MercadoLivre::OrdersClient.new(
      access_token: Marketplace::Credentials::TokenProvider.new(platform_account: conta).access_token,
      seller_id: conta.external_id
    )

    envio = client.bruto("/orders/#{externo}").dig("shipping", "id")

    pacote = client.bruto("/orders/#{externo}")["pack_id"]

    puts "  envio: #{envio.inspect} · pacote: #{pacote.inspect}"
    puts

    vendedor = conta.external_id

    candidatos = [
      [ "por pedido", "/users/#{vendedor}/invoices/orders/#{externo}" ],
      [ "por envio", "/users/#{vendedor}/invoices/shipments/#{envio}" ],
      [ "documentos do pacote", "/packs/#{pacote || externo}/fiscal_documents" ],
      [ "dados do envio (o que já usamos)", "/shipments/#{envio}/invoice_data?siteId=MLB" ],
      [ "lote por período", "/users/#{vendedor}/invoices/sites/MLB/batch_request/period/stream" \
                            "?start=#{Date.current.strftime('%Y%m01')}&end=#{Date.current.strftime('%Y%m%d')}" \
                            "&sale=all&file_types=xml" ]
    ]

    candidatos.each do |rotulo, caminho|
      status, corpo, tipo = client.resposta_crua(caminho)

      # Nada do conteúdo: o XML tem nome e CPF do comprador.
      chave = corpo[/\d{44}/]

      puts format("  %-34s HTTP %-3d %-28s %6d byte(s)%s%s",
                  rotulo, status, tipo.to_s.split(";").first.to_s, corpo.bytesize,
                  corpo.include?("<infNFe") || corpo.include?("<nfeProc") ? " · É NF-e" : "",
                  chave ? " · chave ...#{chave.last(8)}" : "")

      # Só a MENSAGEM do erro, que é o que diz se falta escopo ou se o caminho
      # não existe.
      if status >= 400
        puts "      #{corpo.to_s.gsub(/\s+/, ' ').truncate(180)}"
      end

      sleep 0.5
    rescue StandardError => e
      puts format("  %-34s %s: %s", rotulo, e.class, e.message.to_s.truncate(120))
    end

    puts
    puts "Como ler:"
    puts "  HTTP 200 com É NF-e  -> dá para trazer o XML dessas notas."
    puts "  403 / forbidden      -> falta escopo no app; é permissão, não ausência."
    puts "  404                  -> o caminho não é esse."
    puts
    puts "Nada foi gravado."
  end
end
