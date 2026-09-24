namespace :ml do
  desc "O que o Mercado Livre devolve na nota fiscal dele (SOMENTE LEITURA)"
  task estrutura_da_nota: :environment do
    # Provado: `/users/{vendedor}/invoices/orders/{pedido}` responde 200 com 6 KB
    # de JSON e a chave certa. E o PDF do portal da SEFAZ mostrou o porquê —
    # `verProc: mercadolivre.invoice`: quem emitiu essas notas foi o Mercado
    # Livre, não o Tiny.
    #
    # Antes de montar a importação, o que tem dentro. Item, CFOP, valor,
    # desconto? Se tiver, essas notas entram com a mesma qualidade das do Tiny.
    #
    # Imprime a ESTRUTURA e os campos de dinheiro e de fiscal. Nome, CPF e
    # endereço do comprador vêm nessa resposta e NÃO são impressos: a pergunta é
    # sobre o formato, não sobre quem comprou.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    conta = PlatformAccount.find_by(tenant_id: tenant.id, platform: "mercado_livre", status: "active")

    abort "Nenhuma conta ativa do Mercado Livre." if conta.blank?

    pedido =
      if ENV["PEDIDO"].present?
        Order.find_by(tenant_id: tenant.id, external_id: ENV["PEDIDO"].to_s.strip)
      else
        Order
          .where(tenant_id: tenant.id)
          .where("jsonb_typeof(orders.metadata->'nota_do_envio') = 'object'")
          .order(Arel.sql("RANDOM()"))
          .first
      end

    abort "Pedido não encontrado." if pedido.blank?

    client = Marketplace::MercadoLivre::OrdersClient.new(
      access_token: Marketplace::Credentials::TokenProvider.new(platform_account: conta).access_token,
      seller_id: conta.external_id
    )

    status, corpo, = client.resposta_crua("/users/#{conta.external_id}/invoices/orders/#{pedido.external_id}")

    abort "O Mercado Livre respondeu #{status}." unless status == 200

    dados = JSON.parse(corpo)

    puts "Pedido #{pedido.external_id} · #{corpo.bytesize} byte(s) de resposta"
    puts

    # Campos que NÃO podem ser impressos: são do comprador.
    privados = /name|cpf|cnpj|doc|address|street|phone|email|nick|receiver|buyer|payer|cust/i

    # Campos que interessam: dinheiro, fiscal, identificação do documento.
    fiscais = /amount|value|total|price|qty|quantity|discount|tax|icms|pis|cofins|ipi|cfop|ncm|
               serie|series|number|key|date|status|type|item/xi

    caminhar = lambda do |valor, prefixo, profundidade|
      return if profundidade > 3

      case valor
      when Hash
        valor.each do |chave, dentro|
          caminho = [ prefixo, chave ].compact.join(".")

          if dentro.is_a?(Hash) || dentro.is_a?(Array)
            puts format("  %-52s %s", caminho, dentro.is_a?(Array) ? "[#{dentro.size} item(ns)]" : "{}")

            caminhar.call(dentro.is_a?(Array) ? dentro.first : dentro, caminho, profundidade + 1)
          elsif chave.to_s.match?(privados)
            puts format("  %-52s (campo do comprador, não impresso)", caminho)
          elsif chave.to_s.match?(fiscais)
            puts format("  %-52s %s", caminho, dentro.to_s.truncate(60))
          else
            puts format("  %-52s %s", caminho, dentro.to_s.truncate(40))
          end
        end
      end
    end

    caminhar.call(dados, nil, 0)

    puts
    puts "O que a importação precisa, e se está aqui:"

    texto = corpo.downcase

    {
      "número da nota" => %w[number invoice_number nnf],
      "série" => %w[series serie],
      "chave de acesso" => %w[key access_key chave],
      "valor total" => %w[total_amount amount value],
      "data de emissão" => %w[date_created issue_date data_emissao],
      "itens" => %w[items order_items products],
      "CFOP" => %w[cfop],
      "NCM" => %w[ncm],
      "desconto" => %w[discount desconto],
      "XML" => %w[xml fiscal_document]
    }.each do |rotulo, chaves|
      presente = chaves.any? { |c| texto.include?(c) }

      puts format("  %-18s %s", rotulo, presente ? "SIM" : "não")
    end

    puts
    puts "Nada foi gravado."
  end
end
