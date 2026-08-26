namespace :ml do
  desc "Pergunta ao Mercado Livre quantos pedidos a conta tem, com e sem filtro (SOMENTE LEITURA)"
  task pedidos: :environment do
    # "0 pedidos" tem duas causas com providências opostas: a conta conectada
    # não vende, ou a nossa consulta está errada. As duas se parecem na tela.
    #
    # A mesma técnica que resolveu o "0 títulos no OMIE": perguntar de novo SEM
    # filtro nenhum. Se sem filtro também vier zero, a conta é que está vazia.
    conta = PlatformAccount.find_by(id: ENV["CONTA"]) ||
            PlatformAccount.where(platform: "mercado_livre").order(:id).first

    abort "Nenhuma conta do Mercado Livre cadastrada. Use CONTA=<id>." if conta.blank?

    credencial = conta.marketplace_credential

    abort "A conta ##{conta.id} não tem credencial. Conecte em Integrações." if credencial.blank?

    puts
    puts "Empresa:               ##{conta.tenant_id} #{conta.tenant.name}"
    puts "Conta de marketplace:  ##{conta.id} #{conta.name}"
    puts "Vendedor no cadastro:  #{conta.external_id}"
    puts "Vendedor do token:     #{credencial.external_user_id}"

    if credencial.external_user_id.present? && credencial.external_user_id != conta.external_id
      puts
      puts "ATENÇÃO: os dois divergem. Vale o do TOKEN — reconecte a conta para acertar o cadastro."
    end

    vendedor = credencial.external_user_id.presence || conta.external_id

    token = Marketplace::Credentials::TokenProvider.new(platform_account: conta).access_token

    dias = (ENV["DIAS"] || 30).to_i

    fim = Date.current
    inicio = fim - dias

    puts
    puts "Consultando /orders/search do vendedor #{vendedor}..."
    puts

    consultar(token, vendedor, titulo: "Com filtro de data (#{inicio} a #{fim})",
                               de: inicio, ate: fim)

    sleep 2

    consultar(token, vendedor, titulo: "SEM filtro de data (tudo o que a conta tem)")

    puts
    puts "Como ler:"
    puts "  sem filtro > 0 e com filtro = 0  -> a janela não alcança; o filtro é meu problema."
    puts "  os dois = 0                      -> esta conta não tem pedido nenhum."
    puts "                                      Não é a conta que vende — reconecte a certa."
    puts
    puts "Nada foi gravado."
  end
end

def consultar(token, vendedor, titulo:, de: nil, ate: nil)
  puts "=" * 70
  puts titulo
  puts "=" * 70

  uri = URI.join(ENV["ML_API_HOST"].presence || "https://api.mercadolibre.com", "/orders/search")

  params = { seller: vendedor, limit: 1 }

  if de && ate
    params[:"order.date_created.from"] = "#{de}T00:00:00.000-00:00"
    params[:"order.date_created.to"] = "#{ate}T23:59:59.000-00:00"
  end

  uri.query = URI.encode_www_form(params)

  resposta = buscar(uri, token)

  codigo = resposta.code.to_i

  unless codigo == 200
    puts "  HTTP #{codigo}: #{resposta.body.to_s.strip[0, 300]}"
    return
  end

  corpo = JSON.parse(resposta.body.to_s)

  puts "  Total de pedidos: #{corpo.dig('paging', 'total')}"

  amostra = (corpo["results"] || []).first

  return if amostra.blank?

  puts format("  Exemplo: pedido %s de %s, R$ %s, vendedor %s",
              amostra["id"], amostra["date_created"], amostra["total_amount"],
              amostra.dig("seller", "id"))
rescue StandardError => e
  puts "  ERRO: #{e.class}: #{e.message[0, 200]}"
end

def buscar(uri, token)
  http = Net::HTTP.new(uri.host, uri.port)

  http.use_ssl = true

  http.open_timeout = 5

  http.read_timeout = 30

  requisicao = Net::HTTP::Get.new(uri)

  requisicao["Authorization"] = "Bearer #{token}"

  requisicao["Accept"] = "application/json"

  http.request(requisicao)
end
