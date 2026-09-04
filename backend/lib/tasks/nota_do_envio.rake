namespace :ml do
  desc "Liga a venda à nota pela chave que o Mercado Livre guarda (SIMULA; APLICAR=1 grava)"
  task nota_do_envio: :environment do
    # Casa por CHAVE DE ACESSO, que é única. Identidade, não semelhança — o
    # oposto da inferência por CPF e valor, que recusava 28% por prudência e
    # ainda assim podia errar.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    conta = tenant.platform_accounts.where(status: :active, platform: "mercado_livre").first

    abort "Esta empresa não tem conta ativa do Mercado Livre." if conta.blank?

    aplicar = %w[true 1].include?(ENV["APLICAR"].to_s.strip.downcase)

    limite = (ENV["LIMITE"] || Marketplace::MercadoLivre::NotaDoEnvio::LOTE_PADRAO).to_i

    servico = Marketplace::MercadoLivre::NotaDoEnvio.new(
      tenant: tenant, platform_account: conta, limite: limite, dry_run: !aplicar
    )

    puts aplicar ? "MODO: GRAVANDO" : "MODO: simulação (nada será gravado)"
    puts "Vendas sem nota ainda não perguntadas ao marketplace: #{servico.pendentes.count}"
    puts "Esta execução vai perguntar por #{limite} (duas chamadas cada)."
    puts

    resumo = servico.call

    puts "Ligadas pela chave:                 #{resumo[:ligadas].to_i}"
    puts "Nota existe no ML e não no nosso:   #{resumo[:nao_temos].to_i}"
    puts "Sem nota no marketplace:            #{resumo[:sem_nota_no_ml].to_i}"
    puts "Sem envio:                          #{resumo[:sem_envio].to_i}"
    puts "Falhas:                             #{resumo[:falhas].to_i}"
    puts

    resumo[:exemplos].each { |exemplo| puts "  #{exemplo}" }

    puts
    puts aplicar ? "O ciclo continua o resto sozinho." : "Repita com APLICAR=1 para gravar."
  end
end
