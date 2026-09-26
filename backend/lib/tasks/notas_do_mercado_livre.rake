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

    # TRAVA DE DATA, e ela é a razão desta verificação existir aqui em vez de na
    # cabeça de quem roda.
    #
    # As notas que o Mercado Livre emitiu incluem vendas de JUNHO, anteriores ao
    # início do Tiny. Importar cria nota com data de junho no nosso banco — e é o
    # `omie.envio_a_partir_de` que decide se o ciclo as transforma em título na
    # contabilidade do cliente, sozinho, na próxima volta.
    #
    # Três cenários, um perigoso: marco VAZIO desliga o envio automático inteiro
    # (`SemMarcoInicial` interrompe); marco DEPOIS das notas as deixa fora da
    # fila para sempre; marco ANTES delas manda centenas de títulos sem ninguém
    # decidir. Só o terceiro pede confirmação — e pedir sempre ensinaria a
    # ignorar o aviso.
    marco = Current.with_tenant(tenant) do
      Integracoes::Config.get("omie", :envio_a_partir_de, tenant: tenant).presence&.to_date
    rescue Date::Error
      nil
    end

    mais_antiga = Marketplace::MercadoLivre::NotaFiscal
                    .new(tenant: tenant, platform_account: conta, dry_run: true)
                    .pendentes
                    .includes(:order)
                    .filter_map { |unidade| unidade.order.metadata.to_h.dig("nota_do_envio", "data").presence }
                    .filter_map { |texto| Date.parse(texto) rescue nil }
                    .min

    puts "Marco do envio ao OMIE: #{marco || '(vazio — envio automático desligado)'}"
    puts "Nota mais antiga que esta leva criaria: #{mais_antiga || '(nenhuma com data)'}"

    if aplicar && marco && mais_antiga && marco <= mais_antiga && ENV["CONFIRMO_ENVIO"] != "1"
      abort <<~AVISO

        PARADO. O marco do OMIE (#{marco}) é ANTERIOR ou IGUAL à nota mais antiga
        desta leva (#{mais_antiga}), então o ciclo enviaria estas notas ao OMIE
        sozinho na próxima volta — criando título na contabilidade do cliente sem
        ninguém decidir.

        Duas saídas:
          - mover o marco em Configurações > OMIE para depois de #{mais_antiga}, e
            importar com segurança; ou
          - confirmar que os títulos DEVEM ir, repetindo com CONFIRMO_ENVIO=1.

        Confira antes se o cliente já lançou esse período por outro caminho: o
        envio não é idempotente contra resposta perdida, e duplicata na
        contabilidade dele é caro de desfazer.
      AVISO
    end

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
      puts "  recusas do OMIE liberadas:       #{resumo[:liberadas]}"
      puts "  falhas:                          #{resumo[:falhas]}"
      puts
      puts "Ainda sem comprador depois desta leva: #{servico.quantas_incompletas}"
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
