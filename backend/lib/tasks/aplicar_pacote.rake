namespace :ml do
  desc "Grava o pacote inferido nas vendas sem nota (SIMULA; use APLICAR=1 para gravar)"
  task inferir_pacote: :environment do
    # Aprovado na medição: 18 inferências em 25 vendas de pacote conhecido, 18
    # certas, 0 erradas. O critério era erro ZERO, não taxa alta — vínculo
    # errado põe a nota de uma venda no dinheiro de outra e não dá sinal.
    #
    # O ciclo já faz isto em lotes. Esta tarefa existe para adiantar a base e
    # para conferir antes de gravar.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    conta = tenant.platform_accounts.where(status: :active, platform: "mercado_livre").first

    abort "Esta empresa não tem conta ativa do Mercado Livre." if conta.blank?

    aplicar = %w[true 1].include?(ENV["APLICAR"].to_s.strip.downcase)

    limite = (ENV["LIMITE"] || Marketplace::MercadoLivre::PacotesInferidos::LOTE_PADRAO).to_i

    servico = Marketplace::MercadoLivre::PacotesInferidos.new(
      tenant: tenant, platform_account: conta, limite: limite, dry_run: !aplicar
    )

    pendentes = servico.pendentes.count

    puts aplicar ? "MODO: GRAVANDO" : "MODO: simulação (nada será gravado)"
    puts "Vendas sem nota e sem pacote: #{pendentes}"
    puts "Esta execução vai conferir: #{[ limite, pendentes ].min} (duas consultas por venda)"
    puts

    resumo = servico.call

    puts "Pacotes #{aplicar ? 'gravados' : 'que seriam gravados'}: #{resumo[:inferidos]}"
    puts

    resumo[:exemplos].each { |exemplo| puts "  #{exemplo}" }

    puts
    puts "Não arriscou:"
    %i[nenhuma_nota ambiguo sem_documento mesma_chave chave_vazia sem_pedido].each do |motivo|
      puts format("  %-16s %d", motivo, resumo[motivo].to_i) if resumo[motivo].to_i.positive?
    end

    puts format("  %-16s %d", "falhas", resumo[:falhas].to_i) if resumo[:falhas].to_i.positive?

    puts
    puts aplicar ? "O religamento por pacote roda no próximo ciclo." : "Repita com APLICAR=1 para gravar."
  end
end
