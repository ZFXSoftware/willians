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

  desc "Roda a MESMA busca de títulos que a conciliação usa, e mostra por que ela veio vazia"
  task titulos: :environment do
    # A conciliação disse "0 título(s) no OMIE" numa janela de quatro meses.
    # Zero pode ser: cliente de simulação no lugar do real, filtro de emissão
    # que o OMIE não aceita, ou não haver título mesmo. As três se parecem no
    # log e pedem providências diferentes.
    fim = (ENV["ATE"].presence&.to_date || Date.current)
    inicio = (ENV["DE"].presence&.to_date || fim - 30)

    # Varre TODAS as empresas em vez de assumir uma.
    #
    # A primeira versão desta tarefa pegava `Tenant.order(:id).first` e caiu na
    # "Tenant Demo", que é sobra de teste sem chave nenhuma — e respondeu com
    # confiança que o problema era falta de configuração. Errado, e do jeito
    # mais convincente possível. Num sistema multi-empresa a pergunta "as
    # chaves estão configuradas?" não tem resposta sem dizer DE QUEM.
    puts
    puts "Empresas e chaves do OMIE:"

    empresas = Tenant.order(:id).to_a

    configuradas = empresas.select do |empresa|
      configurada = Current.with_tenant(empresa) { Omie::Client.configured? }

      contas = empresa.platform_accounts.count

      puts format("  #%-4d %-32s chaves: %-4s contas de marketplace: %d",
                  empresa.id, empresa.name.to_s[0, 32], configurada ? "sim" : "NÃO", contas)

      configurada
    end

    escolhida = Tenant.find_by(id: ENV["TENANT"]) || configuradas.first

    if escolhida.blank?
      puts
      puts "Nenhuma empresa tem chave do OMIE resolvida. Sem chave, a conciliação"
      puts "roda contra o cliente de SIMULAÇÃO, que não devolve título nenhum."
      next
    end

    tenant = escolhida

    Current.with_tenant(tenant) do
      puts
      puts "Consultando a empresa ##{tenant.id} #{tenant.name}"

      unless Omie::Client.configured?
        puts "Esta empresa não tem chave do OMIE. Use TENANT=<id> para escolher outra."
        next
      end

      client = Omie::Client.new

      janela_inicio = inicio - Conciliacao::ConciliacaoEngine::EMISSION_LOOKBACK_DAYS

      puts "Janela da conciliação (por EMISSÃO): #{janela_inicio} a #{fim}"
      puts

      totais = Omie::Readers::ReceivableTotals
                 .new(client: client)
                 .call(start_date: janela_inicio, end_date: fim)

      puts "Títulos indexados na janela: #{totais.size}"

      totais.first(5).each { |ref, valor| puts format("  %-24s %s", ref, valor.to_s("F")) }

      puts
      puts "Agora a MESMA conta, sem filtro de data:"

      sleep 4 # o OMIE bloqueia consulta repetida em sequência

      resposta = client.request(
        "financas/contareceber/", "ListarContasReceber",
        pagina: 1, registros_por_pagina: 20
      )

      titulos = resposta["conta_receber_cadastro"] || []

      puts "  Total de títulos na conta: #{resposta['total_de_registros']}"
      puts "  Nesta página: #{titulos.size}"

      if titulos.empty?
        puts
        puts "A conta do OMIE não tem título a receber nenhum. Não é filtro: não há o que conciliar."
        next
      end

      # A chave da conciliação é o número da NF. Se ela vem vazia, casar é
      # impossível mesmo com títulos na janela.
      %w[numero_documento_fiscal numero_documento data_emissao].each do |campo|
        preenchidos = titulos.count { |t| t[campo].present? }

        puts format("  %-28s %d/%d preenchido(s)", campo, preenchidos, titulos.size)
      end

      puts
      puts "  Emissões vistas: #{titulos.filter_map { |t| t['data_emissao'] }.uniq.first(8).join(', ')}"
      puts
      puts "Como ler: se há títulos na conta mas zero na janela, o filtro de emissão"
      puts "não alcança as datas acima. Se numero_documento_fiscal e numero_documento"
      puts "vierem vazios, falta a chave — e aí nenhum filtro resolve."
    end
  end

  desc "Lista os clientes e contas correntes do OMIE, com os códigos para as Configurações"
  task opcoes: :environment do
    # A tela de configurações pede "Código do cliente/fornecedor" e "Conta
    # corrente" e manda obter em ListarClientes / ListarContasCorrentes — o que
    # exige chamar a API na mão. Numa empresa com dezenas de cadastros, isso é
    # pedir para o usuário adivinhar.
    #
    # SOMENTE LEITURA.
    tenant = Tenant.find_by(id: ENV["TENANT"]) ||
             Tenant.order(:id).find { |t| Current.with_tenant(t) { Omie::Client.configured? } }

    abort "Nenhuma empresa com chave do OMIE. Rode `omie:titulos` para ver quais existem." if tenant.blank?

    Current.with_tenant(tenant) do
      abort "A empresa ##{tenant.id} não tem chave do OMIE." unless Omie::Client.configured?

      puts
      puts "Empresa ##{tenant.id} #{tenant.name}"

      client = Omie::Client.new

      busca = ENV["BUSCA"].to_s.strip.downcase

      listar(client, titulo: "CLIENTES / FORNECEDORES  ->  Código do cliente/fornecedor",
                     endpoint: "geral/clientes/", call: "ListarClientes",
                     colecao: "clientes_cadastro", codigo: "codigo_cliente_omie",
                     nome: %w[razao_social nome_fantasia], busca: busca)

      sleep 4 # o OMIE bloqueia consulta repetida em sequência

      listar(client, titulo: "CONTAS CORRENTES  ->  Conta corrente / Conta corrente de destino",
                     endpoint: "geral/contacorrente/", call: "ListarContasCorrentes",
                     colecao: "ListarContasCorrentes", codigo: "nCodCC",
                     nome: %w[descricao cDesc nome], busca: busca)

      puts
      puts "Copie o CÓDIGO (a primeira coluna) para o campo correspondente em"
      puts "Configurações > OMIE. Use BUSCA=mercado para filtrar pelo nome."
      puts
      puts "Estes campos só fazem falta para GRAVAR no OMIE. A conciliação, que"
      puts "só lê, funciona sem nenhum deles."
    end
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

# Uma listagem só, tolerante ao nome da coleção: os endpoints do OMIE não são
# consistentes entre si, e o erro dele costuma dizer o nome certo.
def listar(client, titulo:, endpoint:, call:, colecao:, codigo:, nome:, busca:)
  puts
  puts "=" * 74
  puts titulo
  puts "=" * 74

  resposta = client.request(endpoint, call, pagina: 1, registros_por_pagina: 100)

  registros = resposta[colecao] || resposta.values.find { |v| v.is_a?(Array) } || []

  if registros.empty?
    puts "  Nenhum registro. Chaves recebidas: #{resposta.keys.inspect}"
    return
  end

  linhas = registros.map do |registro|
    rotulo = nome.filter_map { |campo| registro[campo].presence }.first.to_s

    [ registro[codigo], rotulo ]
  end

  linhas = linhas.select { |_, rotulo| rotulo.downcase.include?(busca) } if busca.present?

  puts "  #{linhas.size} de #{resposta['total_de_registros'] || registros.size}"
  puts

  linhas.first(40).each { |cod, rotulo| puts format("  %-16s %s", cod, rotulo[0, 54]) }

  puts "  ... (use BUSCA= para filtrar)" if linhas.size > 40
rescue Omie::Client::ApiError => e
  puts "  ERRO: #{e.message}"
rescue StandardError => e
  puts "  ERRO: #{e.class}: #{e.message[0, 160]}"
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
