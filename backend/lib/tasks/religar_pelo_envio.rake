namespace :ml do
  desc "Liga vendas às notas que já chegaram, usando a resposta guardada do marketplace (APLICAR=1 grava)"
  task religar_pelo_envio: :environment do
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    aplicar = ENV["APLICAR"].to_s == "1"

    puts aplicar ? "MODO: GRAVANDO" : "MODO: SIMULAÇÃO (use APLICAR=1 para gravar)"
    puts

    resumo = Marketplace::MercadoLivre::ReligarPeloEnvio
               .new(tenant: tenant, dry_run: !aplicar)
               .call

    puts "Ligadas: #{resumo[:ligadas]}"
    puts "Canceladas, deixadas soltas de propósito: #{resumo[:canceladas]}"
    puts "A nota ainda não está no nosso banco: #{resumo[:sem_nota_aqui]}"

    if resumo[:exemplos].any?
      puts
      resumo[:exemplos].each { |linha| puts "  #{linha}" }
    end

    puts
    puts "Nada foi gravado." unless aplicar
  end
end
