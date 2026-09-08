namespace :ml do
  desc "O cabeçalho e uma linha crua do relatório de liberações (SOMENTE LEITURA)"
  task cabecalho_do_relatorio: :environment do
    # O glossário oficial do Mercado Pago lista SHIPPING_FEE_AMOUNT,
    # FINANCING_FEE_AMOUNT e COUPON_AMOUNT no relatório de liberações — e
    # nenhuma delas apareceu na linha que guardamos. Duas explicações opostas:
    # ou o arquivo não as traz, ou o nosso leitor as perde.
    #
    # O cabeçalho decide, e ele nunca foi olhado: eu vinha inferindo o formato
    # do arquivo pelo que sobrava depois do nosso próprio parser.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    conta = PlatformAccount.find_by(tenant_id: tenant.id, platform: "mercado_livre", status: "active")

    abort "Nenhuma conta ativa do Mercado Livre nesta empresa." if conta.blank?

    fim = ENV["ATE"].present? ? Date.parse(ENV["ATE"]) : Date.current
    inicio = ENV["DE"].present? ? Date.parse(ENV["DE"]) : (fim - 10)

    puts "Baixando o relatório de #{inicio} a #{fim} (reaproveita o já gerado)..."
    puts

    client = Marketplace::MercadoLivre::ReleasesClient.new(
      access_token: Marketplace::Credentials::TokenProvider.new(platform_account: conta).access_token
    )

    csv = client.csv_for(start_date: inicio, end_date: fim)

    if csv.to_s.strip.empty?
      abort "O relatório veio vazio."
    end

    linhas = csv.lines

    cabecalho = linhas.first.to_s

    separador = [ ",", ";" ].max_by { |candidato| cabecalho.count(candidato) }

    colunas = cabecalho.strip.split(separador).map { |c| c.strip.upcase }

    puts "Arquivo: #{linhas.size} linha(s), separador #{separador.inspect}"
    puts "Colunas: #{colunas.size}"
    puts

    colunas.each_with_index { |coluna, i| puts format("  %2d  %s", i + 1, coluna) }

    puts

    # As colunas do glossário que explicariam a diferença. Dizer se cada uma
    # EXISTE no arquivo separa "o relatório não traz" de "o nosso leitor perde".
    procuradas = %w[
      SHIPPING_FEE_AMOUNT FINANCING_FEE_AMOUNT COUPON_AMOUNT TAXES_AMOUNT
      INSTALLMENTS RECORD_TYPE EXTERNAL_REFERENCE ORDER_ID PACK_ID
    ]

    puts "Colunas do glossário que interessam:"

    procuradas.each do |coluna|
      puts format("  %-22s %s", coluna, colunas.include?(coluna) ? "EXISTE no arquivo" : "não vem neste relatório")
    end

    puts

    fonte = ENV["FONTE"].to_s.strip

    if fonte.blank?
      puts "Para ver uma linha inteira: FONTE=<SOURCE_ID>"

      next
    end

    tabela = CSV.parse(csv, col_sep: separador, headers: true,
                            header_converters: ->(h) { h.to_s.strip.upcase })

    achadas = tabela.select { |linha| linha["SOURCE_ID"].to_s.strip == fonte }

    puts "Linhas com SOURCE_ID #{fonte}: #{achadas.size}"
    puts

    achadas.each_with_index do |linha, i|
      puts "  --- linha #{i + 1} ---"

      # TODAS as colunas, vazias inclusive: é a ausência que responde a pergunta.
      colunas.each { |coluna| puts format("    %-26s %s", coluna, linha[coluna].inspect) }

      puts
    end

    puts "Nada foi gravado."
  end
end
