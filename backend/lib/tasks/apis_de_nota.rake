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

    # VÁRIOS pedidos, não um.
    #
    # Um 404 num pedido específico pode ser daquele pedido — o Mercado Livre não
    # emitiu nota para ele — e não do endpoint. Concluir "o caminho não existe" de
    # um caso é o erro que eu repeti três vezes nesta investigação.
    #
    # E só pedidos cuja nota NÃO está no nosso banco: é sobre essas que a
    # pergunta é.
    quantos = (ENV["QUANTOS"] || 3).to_i

    pedidos =
      if ENV["PEDIDO"].present?
        Order.where(tenant_id: tenant.id, external_id: ENV["PEDIDO"].to_s.strip).to_a
      else
        Order
          .where(tenant_id: tenant.id)
          .where("jsonb_typeof(orders.metadata->'nota_do_envio') = 'object'")
          .order(Arel.sql("RANDOM()"))
          .limit(quantos * 4)
          .to_a
          .reject do |pedido|
            numero = pedido.metadata.dig("nota_do_envio", "numero").to_s.sub(/\A0+/, "")

            numero.blank? || Invoice.where(tenant_id: tenant.id)
                                    .where("regexp_replace(COALESCE(number,''), '\\A0+', '') = ?", numero)
                                    .exists?
          end
          .first(quantos)
      end

    abort "Nenhum pedido com nota do marketplace ausente do nosso banco." if pedidos.none?

    client = Marketplace::MercadoLivre::OrdersClient.new(
      access_token: Marketplace::Credentials::TokenProvider.new(platform_account: conta).access_token,
      seller_id: conta.external_id
    )

    vendedor = conta.external_id

    pedidos.each do |pedido|
    externo = pedido.external_id

    dados = pedido&.metadata&.dig("nota_do_envio") || {}

    puts "Pedido #{externo}"
    puts "  o marketplace diz: NF #{dados['numero']}/#{dados['serie']} de #{dados['data'].to_s.first(10)}"
    puts "  chave: ...#{dados['chave'].to_s.last(8)}"
    puts

    envio = client.bruto("/orders/#{externo}").dig("shipping", "id")

    pacote = client.bruto("/orders/#{externo}")["pack_id"]

    puts "  envio: #{envio.inspect} · pacote: #{pacote.inspect}"
    puts

    # O mês da nota, pela chave (AAMM) e com a data como reserva.
    emitida = begin
      Date.parse(dados["data"].to_s)
    rescue StandardError
      nil
    end

    mes_da_nota = if emitida
                    [ emitida.beginning_of_month.strftime("%Y%m%d"), emitida.end_of_month.strftime("%Y%m%d") ]
                  else
                    [ Date.current.strftime("%Y%m01"), Date.current.strftime("%Y%m%d") ]
                  end

    candidatos = [
      [ "por pedido", "/users/#{vendedor}/invoices/orders/#{externo}" ],
      [ "por envio", "/users/#{vendedor}/invoices/shipments/#{envio}" ],
      [ "documentos do pacote", "/packs/#{pacote || externo}/fiscal_documents" ],
      [ "dados do envio (o que já usamos)", "/shipments/#{envio}/invoice_data?siteId=MLB" ],
      # O período do LOTE é o mês DESTA nota, não o mês corrente: as que
      # interessam são de julho, e pedir setembro devolveria vazio — e vazio aqui
      # eu leria como "o endpoint não serve".
      [ "lote no mês da nota", "/users/#{vendedor}/invoices/sites/MLB/batch_request/period/stream" \
                               "?start=#{mes_da_nota.first}&end=#{mes_da_nota.last}" \
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
    end

    puts "Como ler:"
    puts "  HTTP 200 com É NF-e  -> dá para trazer o XML dessas notas."
    puts "  403 / forbidden      -> falta escopo no app; é permissão, não ausência."
    puts "  404                  -> o caminho não é esse."
    puts
    puts "Nada foi gravado."
  end
end
