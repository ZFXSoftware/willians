namespace :fiscal do
  desc "O número do pedido está DENTRO da NF-e? (NF=851817) — decide se a SEFAZ serve de fonte"
  task xml_da_nota: :environment do
    # A pergunta é de arquitetura: dá para trocar o ERP pela SEFAZ como fonte
    # das notas?
    #
    # A SEFAZ é autoritativa e independe de ERP — mas a conciliação inteira se
    # apoia no NÚMERO DO PEDIDO no marketplace, e quem nos dá isso hoje é o
    # Tiny, no campo `numero_ecommerce`. Se a NF-e não carregar esse número, a
    # SEFAZ entrega o documento fiscal e não entrega a corrente.
    #
    # O XML responde. E dá para olhá-lo pelo próprio Tiny, sem certificado
    # digital — o documento é o mesmo que foi para a SEFAZ.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    Current.tenant = tenant

    escopo = Invoice.where(tenant_id: tenant.id)
                    .where("invoices.metadata->>'numero_ecommerce' IS NOT NULL")

    # Uma nota de CADA canal, e não três quaisquer.
    #
    # A primeira rodada pegou duas da Shopee e uma do Mercado Livre e revelou
    # que o mesmo emissor usa dois caminhos: <xPed> quando o número cabe nos 15
    # caracteres do campo, e texto dentro de <infAdProd> quando não cabe.
    #
    # Se o padrão for esse, ele vale por canal — e é o canal que determina o
    # formato do número do pedido. Uma amostra por canal mostra a regra inteira.
    notas =
      if ENV["NF"].present?
        escopo.where(number: ENV["NF"].to_s.split(",").map(&:strip))
      else
        escopo
          .where("invoices.metadata->'intermediador'->>'nome' IS NOT NULL")
          .order(issued_at: :desc)
          .group_by { |nota| nota.metadata.dig("intermediador", "nome") }
          .values
          .filter_map(&:first)
      end

    abort "Nenhuma nota com número de pedido para inspecionar." if notas.none?

    client = Fiscal::Tiny::V2Client.new

    notas.each do |nota|
      pedido = nota.metadata["numero_ecommerce"].to_s

      puts "=" * 70
      canal = nota.metadata.dig("intermediador", "nome")

      puts "NF #{nota.number}/#{nota.series} · #{canal || 'canal não lido'}"
      puts "  pedido no marketplace: #{pedido} (#{pedido.length} caracteres)"

      sleep 1

      xml = client.obter_xml(nota.external_id)

      if xml.blank?
        puts "  O Tiny não devolveu o XML desta nota."
        puts

        next
      end

      puts "  XML recebido: #{xml.bytesize} bytes"

      procurar_pedido(xml, pedido)

      imprimir_intermediador(xml)

      puts
    end

    puts "Como ler:"
    puts "  <xPed> é campo estruturado da NF-e e aceita 15 caracteres. Pedido"
    puts "  maior que isso não cabe, e o emissor precisa de outro lugar — foi"
    puts "  o que vimos com o Mercado Livre, de 16 dígitos."
    puts
    puts "  o pedido aparece numa TAG da NF-e -> a SEFAZ serve de fonte, e o"
    puts "     produto deixa de depender de qual ERP o cliente usa."
    puts "  o pedido NÃO aparece              -> a SEFAZ dá a nota e não dá a"
    puts "     corrente; ela só serve como rede de segurança para o que falta."
    puts
    puts "Nada foi gravado."
  end

  # Onde, dentro do XML, o número do pedido aparece.
  #
  # Interessa a TAG, não a ocorrência: `xPed` é campo estruturado e sobrevive a
  # qualquer emissor; dentro de `infCpl` é texto livre, que cada sistema
  # escreve do seu jeito e não dá para depender.
  def procurar_pedido(xml, pedido)
    return puts "  (nota sem número de pedido para procurar)" if pedido.blank?

    ocorrencias = xml.scan(/<([A-Za-z0-9_]+)>([^<]*#{Regexp.escape(pedido)}[^<]*)</)

    if ocorrencias.empty?
      puts "  O número do pedido NÃO aparece no XML."

      # Talvez apareça em pedaços, ou com formatação diferente. Dizer isso é
      # melhor do que afirmar ausência categórica.
      puts "  (procurei pela string exata; formatação diferente escaparia)"

      return
    end

    puts "  O número do pedido aparece em:"

    ocorrencias.uniq.first(5).each do |tag, conteudo|
      puts format("    <%s> %s", tag, conteudo.to_s.strip.truncate(70))
    end
  end

  def imprimir_intermediador(xml)
    bloco = xml[%r{<infIntermed>.*?</infIntermed>}m]

    return puts "  Sem grupo <infIntermed> (intermediador) neste XML." if bloco.blank?

    puts "  Intermediador declarado:"

    bloco.scan(/<([A-Za-z0-9_]+)>([^<]+)</).each do |tag, valor|
      puts format("    <%s> %s", tag, valor)
    end
  end
end
