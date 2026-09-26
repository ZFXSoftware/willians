module Marketplace
  module MercadoLivre
    # Traz para o nosso banco a nota fiscal que o MERCADO LIVRE emitiu.
    #
    # Descoberto em 2026-09-24: parte das notas do cliente não sai pelo Tiny.
    # O PDF do portal da SEFAZ mostrou `verProc: mercadolivre.invoice` na NF
    # 41750 — o Mercado Livre emite pelo vendedor, com o CNPJ dele, gravando na
    # MESMA série 2 do Tiny. Daí a numeração alternada, e daí o Tiny não
    # conhecer 232 notas que existem e estão autorizadas.
    #
    # A resposta de `/users/{vendedor}/invoices/orders/{pedido}` traz mais do
    # que o detalhe do Tiny: item com CFOP, NCM e CSOSN, desconto discriminado,
    # regime tributário do emitente, e o caminho do XML.
    #
    # Do comprador, guarda o que a operação EXIGE e nada além: nome e documento.
    #
    # Eu tinha recusado copiar qualquer dado de pessoa, e isso quebrou o envio
    # ao OMIE de 15 notas — ele precisa do cliente para criar o título a
    # receber, e a importação do Tiny já guardava esses dois campos. Recusar
    # deixou o dado ausente só para as notas do Mercado Livre, sem proteger
    # ninguém: o CPF é elemento da própria NF-e.
    #
    # Endereço, telefone e e-mail continuam fora — esses a operação não pede.
    class NotaFiscal
      LOTE_PADRAO = 40

      PAUSA_PADRAO = 0.4

      def initialize(tenant:, platform_account:, client: nil, limite: LOTE_PADRAO,
                     pausa: PAUSA_PADRAO, dry_run: true)
        @tenant = tenant

        @platform_account = platform_account

        @client = client

        @limite = limite

        @pausa = pausa

        @dry_run = dry_run
      end

      # Completa o comprador nas notas que JÁ importamos.
      #
      # As primeiras entraram sem `comprador_nome` e `comprador_documento`,
      # porque eu recusei copiar dado de pessoa — e o OMIE precisa do cliente
      # para criar o título. Reimportar não as alcança: `pendentes` filtra venda
      # SEM nota, e essas já estão ligadas.
      #
      # A recusa se libera sozinha depois: `assinatura_de_envio` inclui o
      # documento, então mudá-lo devolve a nota à fila de envio.
      def completar_compradores
        resumo = Hash.new(0)

        incompletas.limit(limite).each do |nota|
          sleep(pausa) if pausa.to_f.positive?

          pedido = nota.order

          next resumo[:sem_pedido] += 1 if pedido.blank?

          dados = buscar(pedido.external_id)

          next resumo[:sem_resposta] += 1 if dados.blank?

          comprador = comprador_de(dados)

          next resumo[:sem_comprador_no_ml] += 1 if comprador["comprador_documento"].blank?

          resumo[:completadas] += 1

          next if dry_run

          nota.metadata = nota.metadata.to_h.merge(comprador)

          # Preencher o comprador não basta: a recusa gravada continua lá, e o
          # envio pula toda nota que tem uma. `liberar_recusa_se_mudou!` compara
          # a assinatura (valor + documento) e devolve a nota à fila quando o
          # dado que causou a recusa mudou.
          #
          # Ela só era chamada pela importação do Tiny, e as notas do Mercado
          # Livre não passam por lá: 15 ficaram com recusa velha por falta de
          # comprador, DEPOIS de o comprador ter sido preenchido.
          resumo[:liberadas] += 1 if nota.liberar_recusa_se_mudou!

          nota.save!
        rescue StandardError => e
          resumo[:falhas] += 1

          Rails.logger.warn "[NotaFiscalML] completar NF #{nota.number}: #{e.class} #{e.message}"
        end

        resumo
      end

      # Nota que veio do Mercado Livre e está sem o comprador que o título exige.
      def incompletas
        Invoice
          .where(tenant_id: tenant.id)
          .where("invoices.metadata->>'origem' = ?", "mercado_livre")
          .where("invoices.metadata->>'comprador_documento' IS NULL")
          .includes(:order)
      end

      def call
        resumo = Hash.new(0)

        resumo[:exemplos] = []

        pendentes.limit(limite).each do |unidade|
          sleep(pausa) if pausa.to_f.positive?

          processar(unidade, resumo)
        rescue StandardError => e
          resumo[:falhas] += 1

          Rails.logger.warn "[NotaFiscalML] #{unidade.order&.external_id}: #{e.class} #{e.message}"
        end

        resumo
      end

      # Vendas sem nota cujo pedido o marketplace já disse ter nota.
      #
      # A marca `nota_do_envio` guarda a resposta anterior: onde ela é um Hash,
      # o Mercado Livre afirmou que existe nota para aquele envio. É exatamente
      # a população que o Tiny não tem.
      def pendentes
        ReceivableUnit
          .where(tenant_id: tenant.id, platform_account_id: platform_account.id, invoice_id: nil)
          .joins(:order)
          .where("jsonb_typeof(orders.metadata->'nota_do_envio') = 'object'")
          # A nota que JÁ está no nosso banco não precisa de chamada de API.
          #
          # Numa leva de 40, vinte e sete eram notas que já tínhamos: o
          # marketplace foi consultado para descobrir o que um `SELECT`
          # responde. Ligar essas é trabalho do `ReligarPeloEnvio`, que roda no
          # ciclo e não fala com ninguém.
          #
          # Pela CHAVE primeiro, que é a identidade do documento; por número
          # SÓ junto com a série.
          #
          # Comparar número sozinho deixou 10 vendas sem nota para sempre: o
          # cliente emite nas séries 2 e 5, e o Mercado Livre grava na série 2
          # intercalando com o Tiny. Bastava existir a nº N da série 5 para a
          # nº N da série 2 ser considerada "já temos" e nunca ser buscada — uma
          # nota diferente, de outro documento, com o mesmo número.
          .where(
            "NOT EXISTS (SELECT 1 FROM invoices i WHERE i.tenant_id = receivable_units.tenant_id " \
            "AND (" \
            "  (length(regexp_replace(COALESCE(i.access_key,''), '\\D', '', 'g')) = 44 " \
            "   AND regexp_replace(COALESCE(i.access_key,''), '\\D', '', 'g') = " \
            "       regexp_replace(COALESCE(orders.metadata->'nota_do_envio'->>'chave',''), '\\D', '', 'g'))" \
            "  OR (" \
            "   regexp_replace(COALESCE(i.number,''), '\\A0+', '') = " \
            "   regexp_replace(COALESCE(orders.metadata->'nota_do_envio'->>'numero',''), '\\A0+', '') " \
            "   AND regexp_replace(COALESCE(i.series,''), '\\A0+', '') = " \
            "       regexp_replace(COALESCE(orders.metadata->'nota_do_envio'->>'serie',''), '\\A0+', ''))" \
            "))"
          )
          .includes(:order)
          .order(expected_on: :desc)
      end

      # Quantas ainda faltam, para quem roda saber quando parar.
      def quantas_faltam = pendentes.count

      # E quantas notas ainda estão sem o comprador que o título exige.
      #
      # O `completar_compradores` faz 40 por execução. Sem este número, quem
      # rodou uma vez acha que terminou — foi o que aconteceu: 33 completadas,
      # 32 continuaram recusadas pelo OMIE, e a conciliação seguiu acusando
      # "sem comprador" sem ninguém saber que bastava repetir.
      def quantas_incompletas = incompletas.count

      private

      attr_reader :tenant, :platform_account, :limite, :pausa, :dry_run

      def client
        @client ||= OrdersClient.new(
          access_token: Credentials::TokenProvider.new(platform_account: platform_account).access_token,
          seller_id: platform_account.external_id
        )
      end

      def processar(unidade, resumo)
        pedido = unidade.order

        dados = buscar(pedido.external_id)

        return resumo[:sem_resposta] += 1 if dados.blank?

        chave = dados.dig("attributes", "invoice_key").to_s.gsub(/\D/, "")

        return resumo[:sem_chave] += 1 if chave.length != 44

        existente = procurar_existente(chave, dados)

        if existente
          resumo[:ja_tinhamos] += 1

          unless dry_run
            # A chave que faltava vem de graça nesta resposta, e é a identidade do
            # documento: com ela preenchida, a próxima importação reconhece a nota
            # pelo primeiro critério e nem chega no número.
            if existente.access_key.blank?
              existente.update!(access_key: chave)

              resumo[:chaves_preenchidas] = resumo[:chaves_preenchidas].to_i + 1
            end

            ligar!(unidade, existente) unless cancelada?(dados)
          end

          return
        end

        resumo[cancelada?(dados) ? :cancelada : :criada] += 1

        if resumo[:exemplos].size < 5
          resumo[:exemplos] << "NF #{dados['invoice_number']}/#{dados['invoice_series']} " \
                               "R$ #{dados['amount']}#{' (CANCELADA)' if cancelada?(dados)}"
        end

        return if dry_run

        nota = criar!(dados, pedido, chave)

        # Nota cancelada não é a nota da venda: criar é certo, para o histórico
        # existir, mas ligar faria a conciliação esperar um título que não vem.
        ligar!(unidade, nota) unless cancelada?(dados)
      end

      # Pela CHAVE, que é identidade; e então por NÚMERO + SÉRIE da própria
      # resposta.
      #
      # Só a chave não bastava, e o preço foi 20 notas duplicadas: a nota do Tiny
      # entra no banco com `access_key` VAZIA, então a comparação por chave não
      # alcança nenhuma delas. Encontrando 42336/2 do Tiny sem chave, esta
      # importação criava 42336/2 do Mercado Livre ao lado — mesma série, mesmo
      # valor, mesma data, dois registros — e cada um virava título no OMIE.
      #
      # O número vem de `dados`, e não da marca `nota_do_envio`: a marca guarda o
      # que perguntamos, e a resposta é quem diz qual documento de fato existe.
      # Filtrar a fila por uma e criar pela outra é como a duplicata passou pela
      # peneira que eu já tinha consertado.
      def procurar_existente(chave, dados)
        pela_chave = Invoice.where(tenant_id: tenant.id)
                            .where("regexp_replace(COALESCE(access_key,''), '\\D', '', 'g') = ?", chave)
                            .first

        return pela_chave if pela_chave

        numero = dados["invoice_number"].to_s.sub(/\A0+/, "")

        return if numero.blank?

        serie = dados["invoice_series"].to_s.sub(/\A0+/, "")

        Invoice.where(tenant_id: tenant.id)
               .where("regexp_replace(COALESCE(number,''), '\\A0+', '') = ?", numero)
               .where("regexp_replace(COALESCE(series,''), '\\A0+', '') = ?", serie)
               .first
      end

      def buscar(externo)
        status, corpo, = client.resposta_crua(
          "/users/#{platform_account.external_id}/invoices/orders/#{externo}"
        )

        return if status != 200

        JSON.parse(corpo)
      rescue JSON::ParserError
        nil
      end

      def cancelada?(dados)
        dados["status"].to_s == "canceled" || dados.dig("attributes", "cancellation_date").present?
      end

      def criar!(dados, pedido, chave)
        Invoice.create!(
          tenant_id: tenant.id,
          order_id: pedido.id,
          # `ML-` no identificador para nunca colidir com o id do Tiny.
          external_id: "ML-#{dados['id']}",
          number: dados["invoice_number"].to_s,
          series: dados["invoice_series"].to_s,
          access_key: chave,
          # `amount` é o total da nota, já com o desconto abatido — o mesmo que
          # o `valor_nota` do Tiny e o que vira título no OMIE. `items_amount` é
          # o bruto, e guardamos os dois no bloco fiscal.
          total_amount: dados["amount"],
          issued_at: dados["issued_date"] || dados.dig("attributes", "invoice_creation_date"),
          status: cancelada?(dados) ? :cancelled : :issued,
          operation_type: :sale,
          metadata: metadata_de(dados)
        )
      end

      def metadata_de(dados)
        itens = Array(dados["items"])

        {
          # De onde veio, para ninguém confundir depois com nota do ERP.
          "origem" => "mercado_livre",
          # Os dois campos que o título no OMIE exige, com os mesmos nomes que a
          # importação do Tiny usa — senão o mapper não os encontraria.
          **comprador_de(dados),
          # O canal é o próprio Mercado Livre: quem emitiu foi ele.
          "intermediador" => { "nome" => "Mercado Livre", "cnpj" => nil },
          "fiscal" => {
            "regime_tributario" => dados.dig("issuer", "identifications", "crt"),
            "valor_produtos" => dados["items_amount"].to_s,
            "valor_nota" => dados["amount"].to_s,
            "valor_desconto" => desconto_de(itens).to_s,
            "cfops" => atributos(itens, "cfop"),
            "ncms" => atributos(itens, "ncm"),
            "csosns" => atributos(itens, "csosn"),
            # O CST é o equivalente do CSOSN no Regime Normal, e o SaaS terá
            # cliente desse regime. NÃO VERIFICADO contra resposta real: o
            # cliente atual é Simples e só manda CSOSN, então este campo vem
            # vazio hoje. Fica capturado porque o custo é uma linha e a
            # alternativa é descobrir a falta com a apuração de outro cliente
            # errada em produção — o sinal de ST dele sairia em silêncio.
            "csts" => atributos(itens, "cst")
          },
          "mercado_livre" => {
            "invoice_id" => dados["id"],
            # `internal` é nota que o ML emitiu; o outro valor é nota que o
            # vendedor subiu. A distinção diz de quem é a responsabilidade.
            "invoice_source" => dados.dig("attributes", "invoice_source"),
            "protocolo" => dados.dig("attributes", "protocol"),
            "autorizada_em" => dados.dig("attributes", "authorization_date"),
            "cancelada_em" => dados.dig("attributes", "cancellation_date"),
            # O caminho do XML, para buscar o documento quando precisar.
            "xml_location" => dados.dig("attributes", "xml_location"),
            # A nota que esta substitui, quando há cadeia de cancelamento.
            "substitui" => Array(dados.dig("attributes", "reference_invoices"))
                             .filter_map { |r| r["invoice_key"] }
          }.compact
        }
      end

      # Só nome e documento: é o que o título exige. Endereço e telefone vêm na
      # mesma resposta e ficam de fora.
      def comprador_de(dados)
        comprador = dados["recipient"] || {}

        {
          "comprador_nome" => comprador["name"].to_s.strip.presence,
          "comprador_documento" => comprador.dig("identifications", "cpf").presence ||
                                   comprador.dig("identifications", "cnpj").presence
        }
      end

      def desconto_de(itens)
        itens.sum(BigDecimal("0")) do |item|
          item.dig("discount_amount", "unconditional").to_d
        end
      end

      def atributos(itens, chave)
        itens.filter_map { |item| item.dig("fiscal_data", "attributes", chave).presence }.uniq
      end

      def ligar!(unidade, nota)
        unidade.update!(invoice_id: nota.id) if unidade.invoice_id.blank?
      end
    end
  end
end
