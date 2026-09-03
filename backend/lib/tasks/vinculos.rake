namespace :fiscal do
  desc "Liga as notas fiscais ao dinheiro que chegou depois delas (normalmente roda sozinho)"
  task religar_notas: :environment do
    # O ciclo automático já faz isto a cada volta. Esta tarefa existe para
    # adiantar a base de um cliente que já acumulou vendas sem nota ligada.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    antes = ReceivableUnit.where(tenant_id: tenant.id, invoice_id: nil).count

    resumo = Fiscal::VinculoDeNotas.new(tenant: tenant).call

    puts "Lançamentos religados: #{resumo[:lancamentos]}"
    puts "Recebíveis religados:  #{resumo[:recebiveis]}"
    puts
    puts "Recebíveis sem nota: #{antes} -> #{ReceivableUnit.where(tenant_id: tenant.id, invoice_id: nil).count}"
    puts
    puts "O que sobrar é venda cuja nota não está no nosso banco. Veja com:"
    puts "  rake conciliacao:vendas_sem_nf"
  end
end
