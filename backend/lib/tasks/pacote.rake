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
    no_tiny_faltando = 0
    sem_nota_em_lugar_nenhum = 0

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

      if nota
        nota_do_pacote += 1

        puts format("  %s: pacote %s -> NF %s JÁ ESTÁ no nosso banco", referencia, pack, nota.number)

        next
      end

      # Pacote sem nota nossa ainda tem duas explicações: a nota existe no Tiny
      # e não importamos, ou ela não existe. São consertos diferentes, e uma
      # consulta separa.
      sleep 1

      no_tiny = Fiscal::Tiny::Reader.new.por_pedido(pack).first

      if no_tiny
        no_tiny_faltando += 1

        puts format("  %s: pacote %s -> NF %s existe no TINY, não importamos",
                    referencia, pack, no_tiny[:numero])
      else
        sem_nota_em_lugar_nenhum += 1

        puts format("  %s: pacote %s -> nem o Tiny tem nota", referencia, pack)
      end
    rescue StandardError => e
      puts "  #{referencia}: #{e.class} #{e.message}"
    end

    puts
    puts format("  %-46s %d", "tem pacote, e a nota do pacote está aqui", nota_do_pacote)
    puts format("  %-46s %d", "tem pacote, nota está no Tiny e falta importar", no_tiny_faltando)
    puts format("  %-46s %d", "tem pacote, e nem o Tiny tem nota", sem_nota_em_lugar_nenhum)
    puts format("  %-46s %d", "não tem pacote nenhum", sem_pacote)
    puts
    puts "  (com pacote: #{com_pacote})"
    puts
    puts "Como ler cada linha:"
    puts "  nota do pacote aqui   -> o religamento por pack_id resolve sozinho,"
    puts "     bastando ressincronizar os pedidos para gravar o pack_id."
    puts "  falta importar        -> importar o Tiny cobrindo a data resolve."
    puts "  nem o Tiny tem        -> a nota não foi emitida; é assunto do cliente."
    puts "  sem pacote            -> não é o caso do pacote; outra explicação."
    puts
    puts "Nada foi gravado."
  end
end
