namespace :fiscal do
  desc "O XML da NF-e traz os impostos, a natureza da operação e o CFOP? (SOMENTE LEITURA)"
  task impostos_no_xml: :environment do
    # A pergunta do cliente: "conseguimos achar via XML das notas todos os impostos
    # naquelas notas? e a natureza da operação? CFOP?"
    #
    # O que JÁ temos no metadata, medido em 2026-09-28 sobre 7.395 notas:
    #
    #   CFOP                 7.394 de 7.395   (as duas origens)
    #   NCM                  7.394 de 7.395
    #   natureza_operacao    4.269 de 6.371 do Tiny · ZERO das 1.024 do Mercado Livre
    #   CSOSN                  830 de 7.395
    #   CST                      0 de 7.395
    #   ICMS, ST, IPI, ISSQN presentes e TODOS ZERADOS em 6.370 notas do Tiny
    #   PIS, COFINS, vTotTrib   campo nem existe
    #
    # Zero pode ser a verdade — emitente do Simples com CSOSN 102 não destaca ICMS — ou
    # pode ser campo que o ERP não devolve. O JSON do Tiny é a visão DELE do documento; o
    # XML é o documento. Só ele separa as duas hipóteses, e é isso que esta tarefa mede.
    #
    # Lê o XML de uma amostra pelos DOIS caminhos e conta quais tags existem. Não grava.
    $stdout.sync = true

    puts

    tenant = Diagnostico::EmpresaAlvo.anunciar!

    limite = (ENV["LIMITE"].presence || 5).to_i

    # As tags que respondem a pergunta. `vTotTrib` é o total aproximado de tributos da Lei
    # da Transparência — NÃO é imposto pago, e confundir os dois inventaria carga
    # tributária onde não há.
    TAGS = {
      "natOp" => "natureza da operação",
      "CFOP" => "CFOP do item",
      "CSOSN" => "CSOSN (Simples)",
      "CST" => "CST (Regime Normal)",
      "vBC" => "base de cálculo",
      "vICMS" => "ICMS",
      "vICMSST" => "ICMS-ST",
      "vBCST" => "base do ST",
      "vIPI" => "IPI",
      "vPIS" => "PIS",
      "vCOFINS" => "COFINS",
      "vTotTrib" => "total aprox. de tributos",
      "vFrete" => "frete",
      "vDesc" => "desconto",
      "vNF" => "total da nota",
      "vProd" => "produtos"
    }.freeze

    def self.achar(xml, tag)
      valores = xml.scan(%r{<#{tag}>([^<]*)</#{tag}>}).flatten

      return nil if valores.empty?

      valores
    end

    def self.relatar(rotulo, xml)
      puts "  #{rotulo}: #{xml.bytesize} bytes"

      TAGS.each do |tag, nome|
        valores = achar(xml, tag)

        if valores.nil?
          puts format("      %-12s %-26s AUSENTE", tag, nome)

          next
        end

        # Distingue "existe e é zero" de "existe com valor": para emitente do Simples o
        # zero é a verdade, e tratar os dois igual apagaria essa informação.
        numericos = valores.select { |v| v.to_s.match?(/\A-?[\d.]+\z/) }

        resumo =
          if numericos.any? && numericos.all? { |v| v.to_d.zero? }
            "presente, TODOS ZERO"
          elsif numericos.any?
            "presente: #{numericos.reject { |v| v.to_d.zero? }.uniq.first(3).join(', ')}"
          else
            "presente: #{valores.uniq.first(3).join(', ')}"
          end

        puts format("      %-12s %-26s %s", tag, nome, resumo)
      end
    end

    # ---------------------------------------------------------------- caminho do Tiny
    puts "== CAMINHO 1: `nota.fiscal.obter.xml.php` do Tiny =="
    puts

    do_tiny = Invoice
                .where(tenant_id: tenant.id)
                .where("metadata->>'origem' IS NULL OR metadata->>'origem' NOT LIKE '%mercado_livre%'")
                .where.not(external_id: nil)
                .order(issued_at: :desc)
                .limit(limite)
                .to_a

    if do_tiny.empty?
      puts "  Nenhuma nota do Tiny com identificador."
    else
      # Sem token explícito: o cliente resolve o da EMPRESA a cada uso, como as outras
      # tarefas fazem. Passá-lo aqui duplicaria a regra de resolução.
      cliente = Fiscal::Tiny::V2Client.new

      do_tiny.each do |nota|
        xml = cliente.obter_xml(nota.external_id)

        if xml.blank?
          puts "  NF #{nota.number} (#{nota.external_id}): o Tiny não devolveu XML"

          next
        end

        relatar("NF #{nota.number}", xml)

        puts
      rescue StandardError => e
        puts "  NF #{nota.number}: #{e.class} #{e.message}"
      end
    end

    puts
    puts "== CAMINHO 2: `xml_location` da nota do Mercado Livre =="
    puts

    conta = PlatformAccount.find_by(tenant_id: tenant.id, platform: "mercado_livre", status: "active")

    do_ml = Invoice
              .where(tenant_id: tenant.id)
              .where("metadata->>'origem' LIKE '%mercado_livre%'")
              .where("metadata->'mercado_livre'->>'xml_location' IS NOT NULL")
              .order(issued_at: :desc)
              .limit(limite)
              .to_a

    if conta.blank? || do_ml.empty?
      puts "  Nenhuma nota do Mercado Livre com `xml_location`."
    else
      client = Marketplace::MercadoLivre::OrdersClient.new(
        access_token: Marketplace::Credentials::TokenProvider.new(platform_account: conta).access_token,
        seller_id: conta.external_id
      )

      do_ml.each do |nota|
        caminho = nota.metadata.to_h.dig("mercado_livre", "xml_location")

        status, corpo, tipo = client.resposta_crua(caminho)

        # Corpo que não é NF-e é recusa, e tratá-lo como XML fez um diagnóstico meu
        # concluir que cinco canais não traziam o pedido quando o que voltou eram 208
        # bytes de erro.
        unless status == 200 && corpo.to_s.include?("<infNFe")
          puts format("  NF %s: HTTP %s · %s · %d bytes — não é NF-e",
                      nota.number, status, tipo, corpo.to_s.bytesize)

          next
        end

        relatar("NF #{nota.number}", corpo)

        puts
      rescue StandardError => e
        puts "  NF #{nota.number}: #{e.class} #{e.message}"
      end
    end

    puts
    puts "Como ler:"
    puts "  `presente, TODOS ZERO` no ICMS de emitente do Simples é a VERDADE, não falta de"
    puts "     dado: CSOSN 102 não destaca imposto. O XML confirma em vez de supor."
    puts "  `AUSENTE` é o que o XML não carrega e nenhuma leitura vai inventar."
    puts "  `vTotTrib` NÃO é imposto pago — é o total aproximado da Lei da Transparência."
    puts
    puts "Nada foi gravado."
  end
end
