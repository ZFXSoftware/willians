namespace :ml do
  desc "Mede a inferência de pacote contra os casos em que o ML informa o pack (SOMENTE LEITURA)"
  task medir_pacote: :environment do
    # Antes de confiar numa heurística, medi-la onde existe gabarito.
    #
    # 925 pedidos têm `pack_id` vindo da API do Mercado Livre. Rodar a
    # inferência neles e comparar com o valor conhecido diz a taxa de acerto —
    # e transforma "acho que funciona" em número.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    conta = tenant.platform_accounts.where(status: :active, platform: "mercado_livre").first

    abort "Esta empresa não tem conta ativa do Mercado Livre." if conta.blank?

    quantos = (ENV["QUANTOS"] || 25).to_i

    cliente = Marketplace::MercadoLivre::OrdersClient.new(
      access_token: Marketplace::Credentials::TokenProvider.new(platform_account: conta).access_token,
      seller_id: conta.external_id
    )

    inferidor = Marketplace::MercadoLivre::PacoteInferido.new(tenant: tenant, client: cliente)

    # O gabarito: vendas cujo pedido JÁ tem pack_id do Mercado Livre.
    gabarito = ReceivableUnit
                 .where(tenant_id: tenant.id)
                 .joins(:order)
                 .where("orders.metadata->>'pack_id' IS NOT NULL")
                 .includes(:order)
                 .order(Arel.sql("RANDOM()"))
                 .limit(quantos)

    puts "Medindo em #{[ quantos, gabarito.size ].min} venda(s) com pacote conhecido."
    puts

    acertos = 0
    erros = 0
    motivos = Hash.new(0)

    gabarito.each do |unidade|
      sleep 1

      esperado = unidade.order.metadata["pack_id"]

      resultado = inferidor.para(unidade)

      if resultado.pack_id.blank?
        motivos[resultado.motivo] += 1

        puts format("  %-22s esperado %-20s -> não inferiu (%s)",
                    unidade.order.external_id, esperado, resultado.motivo)

        next
      end

      if resultado.pack_id == esperado
        acertos += 1
      else
        erros += 1

        # O erro é o que decide se dá para usar isto: um vínculo errado põe a
        # nota da venda A no dinheiro da venda B.
        puts format("  %-22s esperado %-20s -> INFERIU %s  ERRADO",
                    unidade.order.external_id, esperado, resultado.pack_id)
      end
    end

    total = acertos + erros

    puts
    puts "Acertos: #{acertos}"
    puts "Erros:   #{erros}"
    puts format("Taxa de acerto (quando arriscou): %s",
                total.positive? ? "#{(acertos * 100.0 / total).round(1)}%" : "não arriscou nenhuma vez")
    puts
    puts "Não arriscou: #{motivos.values.sum}"
    motivos.sort_by { |_, quantos| -quantos }.each { |motivo, quantos| puts format("  %-18s %d", motivo, quantos) }

    puts
    puts "Como ler:"
    puts "  erro ZERO e cobertura razoável -> dá para aplicar nas que faltam."
    puts "  qualquer erro                  -> não aplicar: vínculo errado põe a"
    puts "     nota de uma venda no dinheiro de outra, e ninguém percebe depois."
    puts
    puts "Nada foi gravado."
  end
end
