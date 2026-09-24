namespace :ml do
  desc "Traz as notas que o Mercado Livre emitiu (APLICAR=1 grava)"
  task notas_fiscais: :environment do
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    conta = PlatformAccount.find_by(tenant_id: tenant.id, platform: "mercado_livre", status: "active")

    abort "Nenhuma conta ativa do Mercado Livre." if conta.blank?

    aplicar = ENV["APLICAR"].to_s == "1"

    limite = (ENV["LIMITE"] || Marketplace::MercadoLivre::NotaFiscal::LOTE_PADRAO).to_i

    puts aplicar ? "MODO: GRAVANDO" : "MODO: SIMULAÇÃO (use APLICAR=1 para gravar)"
    puts "Até #{limite} venda(s) por execução. Escreve só no nosso banco."
    puts

    resumo = Marketplace::MercadoLivre::NotaFiscal.new(
      tenant: tenant, platform_account: conta, limite: limite, dry_run: !aplicar
    ).call

    puts "Notas a criar:            #{resumo[:criada]}"
    puts "Canceladas (criadas, não ligadas): #{resumo[:cancelada]}"
    puts "Já tínhamos pela chave:   #{resumo[:ja_tinhamos]}"
    puts "Sem resposta do ML:       #{resumo[:sem_resposta]}"
    puts "Sem chave válida:         #{resumo[:sem_chave]}"
    puts "Falhas:                   #{resumo[:falhas]}"

    if resumo[:exemplos].any?
      puts
      resumo[:exemplos].each { |linha| puts "  #{linha}" }
    end

    puts
    puts aplicar ? "Rode `rake conciliacao:rodar TENANT=#{tenant.id} SINCRONIZAR=0`." : "Nada foi gravado."
  end
end
