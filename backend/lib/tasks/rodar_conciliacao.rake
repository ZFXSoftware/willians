namespace :conciliacao do
  desc "Roda a conciliação agora e mostra o resultado (DE=/ATE=; SINCRONIZAR=0 pula a ingestão)"
  task rodar: :environment do
    # A conciliação só era disparável pela tela ou pelo agendador de cinco
    # minutos. Depois de mexer no razão a pessoa quer rodar AGORA e ver o
    # resultado no terminal, em vez de recarregar a tela esperando.
    #
    # Escreve: cria execução, registros e atualiza o status dos repasses. Não
    # toca no OMIE além de LER os títulos.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    fim = ENV["ATE"].present? ? Date.parse(ENV["ATE"]) : Date.current

    inicio = ENV["DE"].present? ? Date.parse(ENV["DE"]) : (fim - 60)

    # A ingestão vem antes por padrão, como no ciclo: conciliar sem trazer os
    # eventos compara o OMIE com o vazio e sai como sucesso com zero.
    #
    # Mas depois de uma limpeza do razão a pessoa quer conciliar o que ESTÁ lá,
    # sem reimportar nada em cima — daí o SINCRONIZAR=0.
    sincronizar = ENV["SINCRONIZAR"].to_s != "0"

    puts "Janela: #{inicio} a #{fim}"
    puts "Ingestão antes de conciliar: #{sincronizar ? 'sim' : 'NÃO (SINCRONIZAR=0)'}"
    puts "Isto LÊ o OMIE e escreve no nosso banco. Nada é enviado ao OMIE."
    puts

    resumo = Conciliacao::ConciliacaoService.new(
      tenant: tenant,
      start_date: inicio,
      end_date: fim,
      sincronizar: sincronizar,
      # Sem `forcar` a conciliação respeita o intervalo mínimo e não faz nada —
      # silêncio que pareceria "rodei e não mudou".
      forcar: true
    ).processar

    puts "Resumo da execução:"
    puts "  #{resumo.inspect.truncate(1200)}"
    puts

    # O que interessa depois de rodar: em que estado cada repasse ficou.
    ids = ConciliacaoRegistro
            .where(tenant_id: tenant.id)
            .where.not(payout_batch_id: nil)
            .group(:payout_batch_id)
            .maximum(:id)
            .values

    registros = ConciliacaoRegistro.where(id: ids).includes(:payout_batch)

    por_status = registros.group_by(&:status)

    puts "Situação dos #{registros.size} repasse(s), pela conferência mais recente de cada:"

    por_status.sort_by { |_, lista| -lista.size }.each do |status, lista|
      puts format("  %-16s %d", status, lista.size)
    end

    puts

    divergentes = registros.reject { |r| r.diferenca.to_d.abs < BigDecimal("0.01") }

    if divergentes.none?
      puts "Nenhum repasse com diferença. Fecharam todos."
    else
      puts "Repasses com diferença, da maior para a menor:"
      puts

      divergentes.sort_by { |r| -r.diferenca.to_d.abs }.first(20).each do |registro|
        puts format("  #%-5s %-12s %12.2f  %s",
                    registro.payout_batch_id, registro.payout_batch&.paid_at&.to_date,
                    registro.diferenca.to_d, registro.status)

        # A observação é onde a decomposição explica a diferença. Imprimir só o
        # número deixaria a pessoa de volta na investigação que ela acabou de
        # sair.
        puts "        #{registro.observacao.to_s.truncate(240)}" if registro.observacao.present?
      end

      puts "  ... (#{divergentes.size - 20} outros)" if divergentes.size > 20
      puts

      puts format("Soma das diferenças: R$ %.2f", divergentes.sum { |r| r.diferenca.to_d })
    end

    puts
  end
end
