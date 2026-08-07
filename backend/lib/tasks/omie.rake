namespace :omie do
  desc "Testa a conexão com o OMIE usando as chaves configuradas (SOMENTE LEITURA)"
  task check: :environment do
    unless Omie::Client.configured?
      abort "OMIE_APP_KEY/OMIE_APP_SECRET não configurados. Preencha o .env da raiz e suba o backend de novo."
    end

    puts "Chaves configuradas."
    puts "Escrita no OMIE: #{Omie::Client.writes_enabled? ? 'HABILITADA (cuidado!)' : 'bloqueada'}"
    puts

    client = Omie::Client.new

    print "Chamando ListarContasReceber... "

    response = client.request(
      "financas/contareceber/",
      "ListarContasReceber",
      pagina: 1,
      registros_por_pagina: 20
    )

    puts "ok"
    puts

    titulos = response["conta_receber_cadastro"] || []

    puts "Total de títulos:  #{response['total_de_registros']}"
    puts "Total de páginas:  #{response['total_de_paginas']}"
    puts "Nesta página:      #{titulos.size}"
    puts

    # Qual campo serve de chave de casamento é a decisão mais importante da
    # conciliação, e só os dados reais respondem.
    candidatos = %w[
      codigo_lancamento_integracao
      numero_documento_fiscal
      numero_documento
      numero_pedido
      chave_nfe
    ]

    puts "Preenchimento dos candidatos a chave de casamento:"

    candidatos.each do |campo|
      preenchidos = titulos.count { |t| t[campo].present? }

      marca = preenchidos == titulos.size ? "  <-- serve" : ""

      puts format("  %-30s %3d/%-3d%s", campo, preenchidos, titulos.size, marca)
    end

    puts
    puts "Campos disponíveis no título (para achar outros candidatos):"
    puts "  #{titulos.first&.keys&.sort&.join(', ')}"
    puts

    titulos.first(3).each_with_index do |t, i|
      puts "Amostra #{i + 1}:"

      (candidatos + %w[valor_documento data_vencimento status_titulo]).each do |campo|
        puts format("  %-30s %s", campo + ":", t[campo].inspect)
      end

      puts
    end

    if ENV["FULL"].present?
      puts "Título completo (FULL=1):"
      puts JSON.pretty_generate(titulos.first)
      puts
    else
      puts "Dica: rode com FULL=1 para ver um título inteiro."
      puts
    end

    puts "Conexão validada. Nenhum dado foi gravado no OMIE."
  rescue Omie::Client::ApiError => e
    abort "OMIE recusou a chamada: #{e.message}"
  rescue Omie::Client::TransportError => e
    abort "Não foi possível alcançar o OMIE: #{e.message}"
  end

  desc "Mostra os códigos de cliente/conta corrente resolvidos por conta de marketplace"
  task settings: :environment do
    Tenant.includes(:platform_accounts).find_each do |tenant|
      puts "Tenant ##{tenant.id} — #{tenant.name}"

      print_settings("  (padrão do tenant)", Omie::Settings.new(tenant: tenant))

      tenant.platform_accounts.each do |account|
        settings = Omie::Settings.new(tenant: tenant, platform_account: account)

        print_settings("  conta ##{account.id} #{account.platform}", settings)
      end

      puts
    end

    puts "Ordem de resolução: platform_account.metadata > tenant.metadata > ENV"
  end
end

def print_settings(label, settings)
  resolved = settings.resolved

  cliente = resolved[:cliente_fornecedor_id] || "FALTANDO"
  conta = resolved[:conta_corrente_id] || "FALTANDO"

  puts "#{label}: cliente=#{cliente} (#{resolved[:origem_cliente]}) " \
       "conta_corrente=#{conta} (#{resolved[:origem_conta]})"
  puts "#{' ' * label.length}  categorias: #{resolved[:categorias].inspect}"
end
