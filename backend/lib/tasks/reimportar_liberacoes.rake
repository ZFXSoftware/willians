namespace :marketplace do
  desc "Relê o relatório de liberações de um período (DE=/ATE=; preenche a procedência que falta)"
  task reimportar: :environment do
    # O botão da tela relê os últimos 30 dias, e isso cobre o repasse recente —
    # mas não os de julho, que é justamente onde a diferença apareceu primeiro.
    #
    # Reimportar NÃO duplica: o lançamento já existente é pulado. O que ele faz
    # de novo é preencher `raw_payload`, a linha original do relatório, que
    # antes era descartada e é quem sabe responder de onde vem cada valor.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    contas = PlatformAccount.where(tenant_id: tenant.id, status: "active")

    contas = contas.where(id: ENV["CONTA"]) if ENV["CONTA"].present?

    if contas.none?
      abort "Nenhuma conta ativa nesta empresa."
    end

    fim = ENV["ATE"].present? ? Date.parse(ENV["ATE"]) : Date.current
    inicio = ENV["DE"].present? ? Date.parse(ENV["DE"]) : (fim - 30)

    abort "DE (#{inicio}) é depois de ATE (#{fim})." if inicio > fim

    puts "Janela: #{inicio} a #{fim}"
    puts "Contas: #{contas.map { |c| "##{c.id} #{c.platform}" }.join(', ')}"
    puts
    puts "Não duplica lançamento: o que já existe é pulado, e só a procedência"
    puts "vazia é preenchida. Valor, data e tipo não são tocados."
    puts

    contas.each do |conta|
      puts "Conta ##{conta.id} (#{conta.platform})..."

      resumo = Marketplace::SincronizacaoService.new(
        tenant: tenant,
        platform_account: conta,
        start_date: inicio,
        end_date: fim,
        # Sem isto a sincronização respeita o intervalo mínimo de 1 hora e não
        # faz nada — silêncio que pareceria "reimportei e não mudou".
        forcar: true
      ).call

      puts "  #{resumo.inspect.truncate(400)}"
    rescue Marketplace::AindaNaoPronto => e
      puts "  O relatório ainda está sendo gerado do lado do marketplace: #{e.message}"
      puts "  Rode de novo daqui a alguns minutos."
    rescue StandardError => e
      puts "  Falhou: #{e.class} #{e.message}"
    end

    puts
    puts "Depois: rake conciliacao:composicao_da_venda TENANT=#{tenant.id} PEDIDO=<id>"
  end
end
