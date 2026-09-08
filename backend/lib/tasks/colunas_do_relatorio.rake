namespace :ml do
  desc "Acrescenta ao relatório de liberações as colunas que faltam (APLICAR=1 grava na conta do cliente)"
  task colunas_do_relatorio: :environment do
    # Medido: o arquivo vem com 15 colunas porque a CONFIGURAÇÃO DA CONTA lista
    # 15. Frete, cupom, parcelamento e o número do pedido existem no relatório
    # de liberações — só não estão selecionados.
    #
    # Isto escreve na conta do Mercado Pago do CLIENTE: o arquivo que ele mesmo
    # baixa passa a ter as colunas novas. Por isso simula por padrão, mostra a
    # configuração inteira antes, e só ACRESCENTA — tirar coluna quebraria quem
    # já lê o formato atual, a nossa importação inclusive.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    conta = PlatformAccount.find_by(tenant_id: tenant.id, platform: "mercado_livre", status: "active")

    abort "Nenhuma conta ativa do Mercado Livre nesta empresa." if conta.blank?

    aplicar = ENV["APLICAR"].to_s == "1"

    # As que faltam, e o motivo de cada uma.
    QUERIDAS = {
      "ORDER_ID" => "o número do pedido — hoje nenhuma linha tem, e o vínculo custa 2 chamadas de API por venda",
      "PACK_ID" => "o pacote, que é como o Tiny grava a nota de compra com mais de um item",
      "EXTERNAL_REFERENCE" => "a referência externa da operação",
      "SHIPPING_FEE_AMOUNT" => "custo de envio",
      "FINANCING_FEE_AMOUNT" => "custo de oferecer parcelamento sem juros",
      "COUPON_AMOUNT" => "desconto oferecido ao comprador",
      "INSTALLMENTS" => "em quantas parcelas a compra foi feita",
      "RECORD_TYPE" => "o tipo do registro, que hoje chega vazio em todas as linhas"
    }.freeze

    puts aplicar ? "MODO: GRAVANDO NA CONTA DO CLIENTE" : "MODO: SIMULAÇÃO (use APLICAR=1 para gravar)"
    puts

    client = Marketplace::MercadoLivre::ReleasesClient.new(
      access_token: Marketplace::Credentials::TokenProvider.new(platform_account: conta).access_token
    )

    atual = client.configuracao

    existentes = Array(atual["columns"]).map { |coluna| coluna["key"].to_s }

    puts "Colunas hoje (#{existentes.size}): #{existentes.join(', ')}"
    puts

    faltando = QUERIDAS.keys - existentes

    if faltando.empty?
      puts "Todas as colunas que queremos já estão configuradas. Nada a fazer."

      next
    end

    puts "A acrescentar (#{faltando.size}):"

    faltando.each { |chave| puts format("  %-22s %s", chave, QUERIDAS[chave]) }

    puts
    puts "Nenhuma coluna atual é removida."
    puts

    unless aplicar
      puts "Simulação. Nada foi enviado ao Mercado Pago."
      puts
      puts "Depois de aplicar, o relatório JÁ GERADO continua no formato antigo:"
      puts "use REGERAR=1 na reimportação para pedir um arquivo novo do período."

      next
    end

    resultado = client.acrescentar_colunas(existentes + faltando)

    puts resultado[:alterado] ? "Configuração atualizada." : "O Mercado Pago não relatou mudança."
    puts

    # Confere lendo de volta, em vez de confiar no que mandamos: o PUT pode
    # aceitar e ignorar uma chave que a conta não suporta, e aí a coluna
    # "configurada" nunca apareceria no arquivo.
    depois = Array(client.configuracao["columns"]).map { |coluna| coluna["key"].to_s }

    puts "Colunas agora (#{depois.size}): #{depois.join(', ')}"
    puts

    recusadas = faltando - depois

    if recusadas.any?
      puts "ATENÇÃO: o Mercado Pago não gravou #{recusadas.join(', ')}."
      puts "Essas colunas não existem neste relatório para esta conta."
    else
      puts "Todas entraram."
    end

    puts
    puts "Próximo passo: rake marketplace:reimportar TENANT=#{tenant.id} DE=... ATE=... REGERAR=1"
  end
end
