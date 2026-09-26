namespace :fiscal do
  desc "As notas canceladas no nosso banco estão canceladas no Mercado Livre? (SOMENTE LEITURA)"
  task status_das_canceladas: :environment do
    # As 20 notas duplicadas trouxeram um achado de graça: nos pares, o lado do
    # Tiny está `cancelled` e o do Mercado Livre `issued`. Se o ML afirma que o
    # documento está autorizado e o nosso registro diz cancelado, uma das duas
    # fontes está velha.
    #
    # Isso decide uma conclusão que eu já dei ao usuário: 31 vendas sem nota
    # "porque a nota foi cancelada e o cliente precisa emitir outra". Se parte
    # delas estiver autorizada no marketplace, a providência não é do cliente — é
    # nossa, e a conciliação está descartando nota válida.
    #
    # CONTROLE, e ele não é opcional: a mesma comparação roda também em notas que
    # nós temos como `issued`. Se o ML disser "cancelada" para essas, então o que
    # não presta é a minha leitura do campo, e nada do resto vale. Vazio e
    # divergência se parecem demais nesta base para eu concluir sem isso.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    conta = PlatformAccount.find_by(tenant_id: tenant.id, platform: "mercado_livre", status: "active")

    abort "Nenhuma conta ativa do Mercado Livre." if conta.blank?

    quantas = (ENV["QUANTAS"] || 25).to_i

    client = Marketplace::MercadoLivre::OrdersClient.new(
      access_token: Marketplace::Credentials::TokenProvider.new(platform_account: conta).access_token,
      seller_id: conta.external_id
    )

    perguntar = lambda do |nota|
      pedido = nota.order

      next [ :sem_pedido, nil ] if pedido.blank?

      status, corpo, = client.resposta_crua(
        "/users/#{conta.external_id}/invoices/orders/#{pedido.external_id}"
      )

      next [ :sem_resposta, nil ] if status != 200

      dados = begin
        JSON.parse(corpo)
      rescue JSON::ParserError
        nil
      end

      next [ :sem_resposta, nil ] if dados.blank?

      cancelada = dados["status"].to_s == "canceled" ||
                  dados.dig("attributes", "cancellation_date").present?

      [ cancelada ? :cancelada_no_ml : :autorizada_no_ml, dados ]
    end

    escolher = lambda do |status|
      Invoice
        .where(tenant_id: tenant.id, status: status, operation_type: :sale)
        .where.not(order_id: nil)
        .includes(:order)
        .order(Arel.sql("RANDOM()"))
        .limit(quantas)
        .to_a
    end

    # ---------------------------------------------------------------- controle
    controle = escolher.call(:issued)

    puts "CONTROLE — #{controle.size} nota(s) que NÓS temos como emitidas:"

    resultado_controle = Hash.new(0)

    controle.each do |nota|
      veredito, = perguntar.call(nota)

      resultado_controle[veredito] += 1

      sleep 0.3
    end

    resultado_controle.sort_by { |_, q| -q }.each { |v, q| puts format("  %-20s %4d", v, q) }

    puts

    if resultado_controle[:cancelada_no_ml].to_i > resultado_controle[:autorizada_no_ml].to_i
      abort "O Mercado Livre diz 'cancelada' para a maioria das notas que temos como EMITIDAS.\n" \
            "Então o campo que eu estou lendo não é o status do documento. Não conclua nada."
    end

    if resultado_controle[:autorizada_no_ml].to_i.zero?
      abort "Nenhuma resposta útil no controle: sem isso não sei se a comparação funciona."
    end

    puts "Controle passou: o ML confirma autorizada para as que temos como emitidas."
    puts

    # ------------------------------------------------------------- as canceladas
    canceladas = escolher.call(:cancelled)

    puts "#{canceladas.size} nota(s) que NÓS temos como CANCELADAS:"

    resultado = Hash.new(0)

    divergentes = []

    canceladas.each do |nota|
      veredito, dados = perguntar.call(nota)

      resultado[veredito] += 1

      if veredito == :autorizada_no_ml && divergentes.size < 12
        divergentes << [ nota, dados["invoice_number"], dados["invoice_series"] ]
      end

      sleep 0.3
    end

    resultado.sort_by { |_, q| -q }.each { |v, q| puts format("  %-20s %4d", v, q) }

    puts

    if divergentes.any?
      puts "DIVERGEM — nós dizemos cancelada, o Mercado Livre diz autorizada:"

      divergentes.each do |nota, numero, serie|
        puts format("  ##%-6d NF %-10s série %-4s origem %-14s emitida %s  R$ %9.2f  (ML: %s/%s)",
                    nota.id, nota.number, nota.series, nota.metadata.to_h["origem"].presence || "—",
                    nota.issued_at&.to_date, nota.total_amount.to_d, numero, serie)
      end

      puts
      puts "Se isto se confirmar em escala, a conclusão que demos sobre as 31 vendas"
      puts "\"canceladas, o cliente precisa reemitir\" está errada para parte delas:"
      puts "a nota vale, e quem a está descartando somos nós."
    else
      puts "Nenhuma divergência na amostra: as canceladas estão canceladas no ML também."
    end

    puts
    puts "Amostra de #{quantas} por lado (QUANTAS= para mudar). Nada foi gravado."
  end
end
