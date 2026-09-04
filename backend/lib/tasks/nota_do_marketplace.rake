namespace :ml do
  desc "O Mercado Livre sabe qual NF-e saiu com o pedido? (SOMENTE LEITURA)"
  task nota_do_pedido: :environment do
    # Fecharam-se os caminhos fiscais: a SEFAZ recusa entregar ao emitente as
    # próprias notas (641), e SPED não existe para empresa do Simples.
    #
    # Sobra a fonte mais óbvia em retrospecto: o marketplace EXIGE a nota para
    # despachar. Se ele guarda a chave, ele sabe de notas emitidas fora do
    # Tiny — que é a pergunta das ~190 vendas sem NF.
    #
    # Qual endpoint responde isso eu não sei de cabeça. Esta tarefa experimenta
    # alguns e imprime o que vier, em vez de eu adivinhar e concluir errado.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    Current.tenant = tenant

    conta = tenant.platform_accounts.where(status: :active, platform: "mercado_livre").first

    abort "Esta empresa não tem conta ativa do Mercado Livre." if conta.blank?

    cliente = Marketplace::MercadoLivre::OrdersClient.new(
      access_token: Marketplace::Credentials::TokenProvider.new(platform_account: conta).access_token,
      seller_id: conta.external_id
    )

    # Vendas SEM nota são o alvo: é nelas que a resposta importa.
    unidades = ReceivableUnit
                 .where(tenant_id: tenant.id, invoice_id: nil)
                 .where.not(order_id: nil)
                 .includes(:order)
                 .order(Arel.sql("RANDOM()"))
                 .limit((ENV["QUANTOS"] || 3).to_i)

    abort "Nenhuma venda sem nota para investigar." if unidades.none?

    unidades.each do |unidade|
      pedido = unidade.order.external_id

      pack = unidade.order.metadata.to_h["pack_id"]

      puts "=" * 70
      puts "Pedido #{pedido}#{pack ? " · pacote #{pack}" : ''} · liberado em #{unidade.expected_on}"

      # O id do ENVIO vem de dentro do pedido. `/orders/{id}/shipments` não é
      # caminho do Mercado Livre — a primeira sonda perguntou nele, não deu
      # erro, e eu quase li isso como resposta.
      detalhe =
        begin
          cliente.bruto("/orders/#{pedido}")
        rescue StandardError
          {}
        end

      envio = detalhe.dig("shipping", "id")

      caminhos = [
        "/orders/#{pedido}",
        "/orders/#{pedido}/billing_info",
        ("/packs/#{pack}/fiscal_documents" if pack.present?),
        ("/shipments/#{envio}" if envio.present?),
        ("/shipments/#{envio}/items" if envio.present?),
        # 400 e não 404: o endpoint EXISTE e o pedido é que está incompleto.
        # Ele exige o site, que no Brasil é MLB.
        ("/shipments/#{envio}/invoice_data?siteId=MLB" if envio.present?)
      ].compact

      puts "  envio: #{envio || 'o pedido não informa'}"

      caminhos.each do |caminho|
        sleep 1

        resultado =
          begin
            cliente.bruto(caminho)
          rescue StandardError => e
            puts format("  %-42s %s", caminho, "#{e.class}: #{e.message.to_s[0, 60]}")

            next
          end

        # A chave da NF-e tem 44 dígitos. Procurá-la no payload inteiro é mais
        # confiável que apostar num nome de campo.
        chaves = resultado.to_json.scan(/\d{44}/).uniq

        puts format("  %-42s %s", caminho,
                    chaves.any? ? "CHAVE ENCONTRADA: #{chaves.join(', ')}" : "sem chave de NF-e")

        # Nomes de campo que parecem fiscais, para o caso de a chave vir
        # formatada ou o dado estar noutro formato.
        fiscais = campos_fiscais(resultado)

        puts "    campos fiscais: #{fiscais.join(', ')}" if fiscais.any?
      end

      puts
    end

    puts "Como ler:"
    puts "  404 ou 403 num caminho -> aquele endpoint não existe ou a conta não"
    puts "     tem permissão; não é resposta sobre a nota."
    puts "  chave encontrada -> o marketplace sabe qual NF saiu com o pedido,"
    puts "     e é dele que vem a resposta sobre as vendas sem nota."
    puts "  nenhuma chave    -> ele não guarda, e a nota daquela venda não"
    puts "     existe em fonte nenhuma que a gente alcance."
    puts
    puts "Nada foi gravado."
  end

  def campos_fiscais(no, achados = [])
    case no
    when Hash
      no.each do |chave, valor|
        achados << chave.to_s if chave.to_s.match?(/invoice|fiscal|nfe|nota|billing/i)

        campos_fiscais(valor, achados)
      end
    when Array
      no.each { |item| campos_fiscais(item, achados) }
    end

    achados.uniq
  end
end
