namespace :ml do
  desc "Pergunta ao Mercado Livre o pacote das vendas sem nota (SOMENTE LEITURA)"
  task pacote: :environment do
    # A hipótese: quando o comprador leva mais de um item, o ML cria um PACK
    # com id próprio, a nota é emitida para o pacote, e o Tiny grava o id do
    # pack em numero_ecommerce — enquanto o extrato fala do pedido individual.
    #
    # Contagem não decide isso: as candidatas do Mercado Livre são 1064 e as
    # vendas sem nota são 543, e os dois números são compatíveis com a hipótese
    # e com a explicação banal (nota cuja venda não entrou no extrato).
    #
    # Quem decide é o próprio Mercado Livre, uma chamada por pedido.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    Current.tenant = tenant

    conta = tenant.platform_accounts.where(status: :active, platform: "mercado_livre").first

    abort "Esta empresa não tem conta ativa do Mercado Livre." if conta.blank?

    quantos = (ENV["QUANTOS"] || 5).to_i

    sem_nota = ReceivableUnit
                 .where(tenant_id: tenant.id, invoice_id: nil)
                 .where.not(order_id: nil)
                 .includes(:order)
                 .order(Arel.sql("RANDOM()"))
                 .limit(quantos)

    cliente = Marketplace::MercadoLivre::OrdersClient.new(
      access_token: Marketplace::Credentials::TokenProvider.new(platform_account: conta).access_token,
      seller_id: conta.external_id
    )

    com_pacote = 0
    sem_pacote = 0
    nota_do_pacote = 0

    sem_nota.each do |unidade|
      referencia = unidade.order&.external_id

      next if referencia.blank?

      sleep 1

      pedido = cliente.order(referencia)

      pack = pedido[:pack_id]

      if pack.blank?
        sem_pacote += 1

        puts "  #{referencia}: sem pacote"

        next
      end

      com_pacote += 1

      # A prova: existe nota nossa pendurada no id do PACOTE?
      nota = Invoice
               .where(tenant_id: tenant.id)
               .where("invoices.metadata->>'numero_ecommerce' = ?", pack)
               .first

      nota_do_pacote += 1 if nota

      puts format("  %s: pacote %s -> %s", referencia, pack,
                  nota ? "NF #{nota.number} JÁ ESTÁ no nosso banco" : "sem nota nossa para o pacote")
    rescue StandardError => e
      puts "  #{referencia}: #{e.class} #{e.message}"
    end

    puts
    puts "Com pacote:            #{com_pacote}"
    puts "Sem pacote:            #{sem_pacote}"
    puts "Pacote com nota nossa: #{nota_do_pacote}"
    puts
    puts "Como ler:"
    puts "  a maioria com pacote E com nota -> hipótese confirmada; o religamento"
    puts "     por pack_id resolve, bastando ressincronizar os pedidos."
    puts "  a maioria sem pacote            -> a hipótese cai, e a explicação é"
    puts "     outra: venda cuja nota não foi emitida ou não foi importada."
    puts
    puts "Nada foi gravado."
  end
end
