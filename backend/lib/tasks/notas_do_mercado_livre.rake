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

    servico = Marketplace::MercadoLivre::NotaFiscal.new(
      tenant: tenant, platform_account: conta, limite: limite, dry_run: !aplicar
    )

    # COMPLETAR=1 conserta as notas que JÁ importamos sem o comprador.
    #
    # As primeiras entraram assim por uma recusa minha de copiar dado de pessoa,
    # e o OMIE precisa do cliente para criar o título. Reimportar não as alcança:
    # a venda delas já está ligada, então saíram da fila.
    if ENV["COMPLETAR"] == "1"
      resumo = servico.completar_compradores

      puts "Notas a completar com o comprador: #{resumo[:completadas]}"
      puts "  sem comprador no Mercado Livre:  #{resumo[:sem_comprador_no_ml]}"
      puts "  sem resposta / sem pedido:       #{resumo[:sem_resposta] + resumo[:sem_pedido]}"
      puts "  falhas:                          #{resumo[:falhas]}"
      puts
      puts aplicar ? "A recusa do OMIE se libera sozinha: a assinatura do envio mudou." : "Nada foi gravado."

      next
    end

    resumo = servico.call

    puts "Notas a criar:            #{resumo[:criada]}"
    puts "Canceladas (criadas, não ligadas): #{resumo[:cancelada]}"
    puts "Já tínhamos pela chave:   #{resumo[:ja_tinhamos]}"
    puts "Sem resposta do ML:       #{resumo[:sem_resposta]}"
    puts "Sem chave válida:         #{resumo[:sem_chave]}"
    puts "Falhas:                   #{resumo[:falhas]}"
    puts
    puts "Ainda sem nota depois desta leva: #{servico.quantas_faltam}"

    if resumo[:exemplos].any?
      puts
      resumo[:exemplos].each { |linha| puts "  #{linha}" }
    end

    puts
    puts aplicar ? "Rode `rake conciliacao:rodar TENANT=#{tenant.id} SINCRONIZAR=0`." : "Nada foi gravado."
  end
end
