namespace :canais do
  desc "Corrige o canal dos pedidos já criados errado (SIMULA; use APLICAR=1 para gravar)"
  task reatribuir: :environment do
    # O InvoiceSync novo só acerta pedido NOVO. Os que já existem continuam
    # como foram criados — e foram criados pela regra antiga, "só existe uma
    # conta ativa, deve ser essa". Numa amostra de 40 notas do cliente, 23
    # eram de outros canais e todas viraram pedido do Mercado Livre.
    #
    # Simula por padrão. São milhares de pedidos numa base de produção, e o que
    # some daqui reaparece como venda faltando na conciliação de alguém.
    tenant = Tenant.find_by(id: ENV["TENANT"]) || Tenant.order(:id).first

    abort "Nenhuma empresa. Use TENANT=<id>." if tenant.blank?

    aplicar = %w[true 1].include?(ENV["APLICAR"].to_s.strip.downcase)

    $stdout.sync = true

    puts
    puts "Empresa: ##{tenant.id} #{tenant.name}"
    puts aplicar ? "MODO: GRAVANDO" : "MODO: simulação (nada será gravado)"
    puts

    contas = tenant.platform_accounts.where(status: :active).index_by(&:platform)

    mudancas = Hash.new(0)
    protegidos = Hash.new(0)
    total = 0

    # Só pedidos que o próprio InvoiceSync criou a partir da nota.
    #
    # Pedido que veio da API do marketplace é fato: ele existe lá, e a NF-e não
    # tem autoridade para contradizer isso. Sobrescrever seria trocar um dado
    # confirmado por uma dedução.
    escopo = Invoice
               .where(tenant_id: tenant.id)
               .where("invoices.metadata->'intermediador'->>'nome' IS NOT NULL")
               .where.not(order_id: nil)
               .includes(:order)

    escopo.find_each do |nota|
      pedido = nota.order

      next if pedido.blank?

      next if pedido.metadata.to_h["origem"] != "tiny_invoice_sync"

      canal = Fiscal::Tiny::Canal.para(nota.metadata.dig("intermediador", "nome"), tenant: tenant)

      next if canal.blank? || canal == pedido.platform

      total += 1

      # Pedido com dinheiro do marketplace atual não é reatribuído às cegas.
      #
      # Se existe lançamento ligado a ele, alguma ingestão o reconheceu como
      # daquela conta — e trocar a plataforma por baixo tiraria a venda da
      # conciliação onde o dinheiro dela está. Estes saem na lista para serem
      # olhados um a um.
      if FinancialEntry.where(tenant_id: tenant.id, order_id: pedido.id).exists?
        protegidos["#{pedido.platform} -> #{canal}"] += 1

        next
      end

      mudancas["#{pedido.platform} -> #{canal}"] += 1

      next unless aplicar

      pedido.update!(
        platform: canal,
        # Canal sem conta (Magalu, TikTok, venda própria) fica com o pedido
        # reconhecido e SEM conta: é o que o tira da conciliação do Mercado
        # Livre sem inventar uma integração que não existe.
        platform_account_id: contas[canal]&.id
      )
    end

    puts "Pedidos com canal divergente: #{total}"
    puts

    if mudancas.any?
      puts aplicar ? "Reatribuídos:" : "Seriam reatribuídos:"

      mudancas.sort_by { |_, quantos| -quantos }.each { |de_para, quantos| puts format("  %-34s %d", de_para, quantos) }

      puts
    end

    if protegidos.any?
      puts "NÃO tocados por terem lançamento no extrato:"

      protegidos.sort_by { |_, quantos| -quantos }.each { |de_para, quantos| puts format("  %-34s %d", de_para, quantos) }

      puts
      puts "  Estes têm dinheiro ligado à conta atual. Trocar a plataforma por"
      puts "  baixo tiraria a venda da conciliação onde o dinheiro dela está."
      puts
    end

    if total.zero?
      puts "Nada a corrigir. Confira se os canais estão mapeados em Configurações"
      puts "e se o ciclo automático já leu o intermediador das notas."
    elsif !aplicar
      puts "SIMULAÇÃO: repita com APLICAR=1 para gravar."
    end
  end
end
