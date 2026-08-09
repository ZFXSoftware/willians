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

  desc "Procura, SOMENTE LEITURA, o elo entre o pedido do marketplace e a nota fiscal"
  task nfe_check: :environment do
    abort "OMIE_APP_KEY/OMIE_APP_SECRET não configurados." unless Omie::Client.configured?

    client = Omie::Client.new

    pausa = (ENV["PAUSA"] || 4).to_f

    puts "Procurando o elo pedido do marketplace -> nota fiscal."
    puts "A conciliação casa por número de NF; falta saber de onde vem esse número."
    puts

    sondar(client, pausa,
           titulo: "NOTAS FISCAIS EMITIDAS",
           endpoint: "produtos/nfconsultar/",
           call: "ListarNF",
           params: { pagina: 1, registros_por_pagina: 3 },
           colecao: %w[nfCadastro nf_cadastro])

    sondar(client, pausa,
           titulo: "PEDIDOS DE VENDA",
           endpoint: "produtos/pedido/",
           call: "ListarPedidos",
           params: { pagina: 1, registros_por_pagina: 3, apenas_importado_api: "N" },
           colecao: %w[pedido_venda_produto pedidos])

    puts
    puts "Como ler o resultado:"
    puts "  - se algum campo trouxer o id do pedido do marketplace (algo como"
    puts "    701-..., 2000..., ou um código do TrackCash), o elo existe no Omie"
    puts "    e a conciliação fecha sem depender das APIs de marketplace."
    puts "  - se não trouxer, o elo terá que vir da Invoices API da Amazon ou do"
    puts "    sistema que emite as notas."
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

# --- Auxiliares da sondagem de NF-e -----------------------------------------

# Nomes que costumam guardar a referência de origem de um pedido.
CANDIDATOS_ELO = /pedido|order|integracao|integração|origem|marketplace|canal|externo|observ/i

def sondar(client, pausa, titulo:, endpoint:, call:, params:, colecao:)
  puts "=" * 70
  puts titulo
  puts "=" * 70

  sleep(pausa)

  resposta = client.request(endpoint, call, params)

  registros = colecao.filter_map { |c| resposta[c] }.first

  if registros.blank?
    puts "  Resposta sem a coleção esperada (#{colecao.join(' ou ')})."
    puts "  Chaves recebidas: #{resposta.keys.inspect}"
    return
  end

  total = resposta["total_de_registros"] || resposta["nTotRegistros"] || registros.size
  puts "  Registros no total: #{total}"
  puts

  campos = achatar(registros.first)

  puts "  Campos com valor no primeiro registro: #{campos.size}"
  puts

  elos = campos.select { |caminho, valor| caminho.match?(CANDIDATOS_ELO) && valor.present? }

  if elos.any?
    puts "  CANDIDATOS A ELO COM O PEDIDO:"
    elos.each { |caminho, valor| puts format("    %-52s %s", caminho, valor.to_s[0, 60]) }
  else
    puts "  Nenhum campo com cara de referência de pedido neste registro."
  end

  puts
  puts "  Identificadores fiscais:"
  campos.select { |c, _| c.match?(/chave|nfe|numero|serie|danfe/i) }
        .first(10)
        .each { |caminho, valor| puts format("    %-52s %s", caminho, valor.to_s[0, 60]) }

  puts
  puts "  Todos os caminhos disponíveis (para achar o que eu não previ):"
  campos.keys.each_slice(3) { |grupo| puts "    #{grupo.join('  |  ')}" }
rescue Omie::Client::ApiError => e
  # O erro do Omie costuma dizer o nome certo do parâmetro.
  puts "  ERRO: #{e.message}"
rescue StandardError => e
  puts "  ERRO: #{e.class}: #{e.message[0, 160]}"
end

# Transforma a resposta aninhada num mapa caminho => valor, só com folhas
# preenchidas — é o que permite enxergar campos que eu não anteciparia.
def achatar(objeto, prefixo = "", acc = {})
  case objeto
  when Hash
    objeto.each { |k, v| achatar(v, prefixo.empty? ? k.to_s : "#{prefixo}.#{k}", acc) }
  when Array
    objeto.first(1).each_with_index { |v, i| achatar(v, "#{prefixo}[#{i}]", acc) }
  else
    acc[prefixo] = objeto unless objeto.nil? || objeto.to_s.strip.empty?
  end

  acc
end
