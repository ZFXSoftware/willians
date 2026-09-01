module Fiscal
  module Tiny
    # Traz as notas fiscais do Tiny para o nosso modelo e amarra a corrente:
    #
    #   pedido do marketplace -> nota fiscal -> lançamentos e recebíveis
    #
    # A tabela `invoices` existia desde o começo e nunca era populada; é ela
    # que passa a carregar o número da NF, que é a chave de casamento com o
    # título no Omie.
    class InvoiceSync
      SITUACOES = {
        /cancelad/i => :cancelled,
        /denegad/i => :denied
      }.freeze

      def initialize(tenant:, reader: nil, platform_account: nil)
        @tenant = tenant

        @reader = reader || Reader.new

        @platform_account = platform_account

        @resumo = Hash.new(0)
      end

      # `devolucoes: true` lê as notas de ENTRADA — é assim que a NF de
      # devolução volta do Tiny (briefing 2.8).
      def call(start_date:, end_date:, devolucoes: false)
        Current.with_tenant(tenant) do
          @devolucoes = devolucoes

          notas =
            if devolucoes
              reader.notas_de_devolucao(start_date: start_date, end_date: end_date)
            else
              reader.notas_fiscais(start_date: start_date, end_date: end_date)
            end

          resumo[:lidas] = notas.size

          pedidos = mapear_pedidos(notas)

          notas.each { |nota| processar(nota, pedidos) }

          registrar_resultado!(start_date, end_date)

          resumo
        end
      rescue StandardError => e
        registrar_falha!(e)

        raise
      end

      private

      attr_reader :tenant,
                  :reader,
                  :resumo

      # O desfecho fica gravado na empresa.
      #
      # A importação roda em fila: quem apertou o botão recebe "enfileirado" e
      # nada mais. Sem registrar aqui, a tela não tem como dizer se deu certo,
      # quantas notas vieram, ou se o Tiny recusou o token — e "enfileirado"
      # sozinho é indistinguível de sucesso e de falha.
      def registrar_resultado!(start_date, end_date)
        gravar(
          "em" => Time.current,
          "periodo" => "#{start_date} a #{end_date}",
          "lidas" => resumo[:lidas],
          "criadas" => resumo[:criadas],
          "atualizadas" => resumo[:atualizadas],
          "pedidos_criados" => resumo[:pedidos_criados],
          "sem_pedido" => resumo[:sem_pedido],
          "sem_plataforma" => resumo[:sem_plataforma],
          "erro" => nil
        )
      end

      def registrar_falha!(erro)
        gravar("em" => Time.current, "erro" => "#{erro.class}: #{erro.message}".truncate(300))
      rescue StandardError => e
        # Não deixar o registro do erro esconder o erro de verdade.
        Rails.logger.error "[InvoiceSync] não consegui gravar a falha: #{e.message}"
      end

      def gravar(resultado)
        tenant.update_columns(
          metadata: tenant.metadata.merge("tiny_ultima_importacao" => resultado.compact),
          updated_at: Time.current
        )
      end

      # Uma consulta só para todos os pedidos referenciados nas notas.
      def mapear_pedidos(notas)
        refs = notas.filter_map { |n| n[:numero_ecommerce] }.uniq

        return {} if refs.empty?

        criar_pedidos_faltantes!(notas, refs)

        Order
          .where(tenant_id: tenant.id, external_id: refs)
          .pluck(:external_id, :id)
          .to_h
      end

      # A NF é a única fonte que tem o número do PEDIDO do marketplace.
      #
      # O relatório de liberações do Mercado Livre não traz esse número, então
      # esperar que o pedido já exista significava descartar tudo: com o razão
      # vindo só do extrato, nenhuma nota encontraria pedido e o sync contaria
      # 4027 vezes `sem_pedido`. Criar o pedido a partir da nota é o que dá
      # início à corrente pedido -> NF -> título.
      #
      # O pedido nasce só com o número; o conteúdo (comprador, valor, datas)
      # vem depois, do marketplace.
      def criar_pedidos_faltantes!(notas, refs)
        conhecidos = Order.where(tenant_id: tenant.id, external_id: refs).pluck(:external_id).to_set

        faltando = notas.reject { |n| n[:numero_ecommerce].blank? || conhecidos.include?(n[:numero_ecommerce]) }

        return if faltando.empty?

        agora = Time.current

        linhas =
          faltando.filter_map do |nota|
            canal, conta = destino_de(nota)

            # `next resumo[...] += 1` devolveria o INTEIRO, que o filter_map
            # considera resultado válido — e a lista de linhas ganharia um
            # número no lugar de um pedido.
            if canal.blank?
              resumo[:sem_plataforma] += 1

              next
            end

            {
              tenant_id: tenant.id,
              # Pode ser NULO: canal reconhecido sem conta é exatamente o caso
              # do Magalu e do TikTok, que ainda não têm integração. O pedido
              # nasce com o canal certo e fica FORA de qualquer conciliação,
              # em vez de sujar a do Mercado Livre.
              platform_account_id: conta&.id,
              platform: canal,
              external_id: nota[:numero_ecommerce],
              status: "pending",
              currency: "BRL",
              metadata: { "origem" => "tiny_invoice_sync" },
              created_at: agora,
              updated_at: agora
            }
          end

        return if linhas.empty?

        Order.insert_all(linhas.uniq { |l| l[:external_id] }, unique_by: :idx_orders_unique)

        resumo[:pedidos_criados] += linhas.size
      end

      # Para qual canal vai o pedido desta nota.
      #
      # Primeiro o intermediador declarado na NF-e, que é fato: numa amostra de
      # 40 notas do cliente, 23 vinham de Shopee, Amazon, Magalu e TikTok e
      # todas viravam pedido do Mercado Livre, porque a regra era "só existe
      # uma conta ativa, deve ser essa".
      #
      # Sem intermediador, a regra antiga continua valendo — é tudo o que se
      # sabe, e recusar tudo pararia a corrente inteira em notas antigas.
      def destino_de(nota)
        canal = Canal.para(intermediador_de(nota), tenant: tenant)

        return [ canal, contas_por_canal[canal] ] if canal.present?

        conta = conta_da_nota

        conta ? [ conta.platform, conta ] : [ nil, nil ]
      end

      def contas_por_canal
        @contas_por_canal ||= tenant
                                .platform_accounts
                                .where(status: :active)
                                .index_by(&:platform)
      end

      # O intermediador vem da nota COMPLETA do Tiny, uma consulta por nota —
      # caro demais para o caminho da importação. Quem o busca é a tarefa
      # `tiny:intermediador`, em lote e retomável; aqui só se lê o que ela já
      # gravou.
      def intermediador_de(nota)
        intermediadores[nota[:id_tiny]]
      end

      def intermediadores
        @intermediadores ||=
          Invoice
            .where(tenant_id: tenant.id)
            .where("invoices.metadata->'intermediador'->>'nome' IS NOT NULL")
            .pluck(:external_id, Arel.sql("invoices.metadata->'intermediador'->>'nome'"))
            .to_h
      end

      # A nota do Tiny não diz de qual marketplace ela é. Com uma conta só na
      # empresa, não há ambiguidade. Com várias, atribuir seria chute — e um
      # pedido no marketplace errado estragaria a conciliação daquela conta.
      def conta_da_nota
        return @conta_da_nota if defined?(@conta_da_nota)

        @conta_da_nota = resolver_conta_da_nota
      end

      def resolver_conta_da_nota
        return @platform_account if @platform_account

        contas = tenant.platform_accounts.where(status: :active).to_a

        return contas.first if contas.one?

        Rails.logger.warn(
          "[InvoiceSync] empresa ##{tenant.id} tem #{contas.size} contas de marketplace ativas; " \
          "não dá para saber de qual marketplace é a nota. Informe platform_account."
        )

        nil
      end

      def processar(nota, pedidos)
        return resumo[:sem_referencia] += 1 if nota[:numero_ecommerce].blank?

        return resumo[:sem_numero] += 1 if nota[:numero].blank?

        order_id = pedidos[nota[:numero_ecommerce]]

        # A NF pode chegar antes de o pedido ter sido ingerido do marketplace.
        # Contamos para não sumir com o caso.
        return resumo[:sem_pedido] += 1 if order_id.blank?

        invoice = upsert!(nota, order_id)

        # Só a NF de venda amarra lançamentos e recebíveis: a de devolução
        # roubaria o vínculo da venda e quebraria a baixa.
        vincular_lancamentos!(invoice, order_id) unless @devolucoes
      end

      def upsert!(nota, order_id)
        invoice =
          Invoice.find_or_initialize_by(
            tenant_id: tenant.id,
            external_id: nota[:id_tiny] || "TINY-#{nota[:numero]}-#{nota[:serie]}"
          )

        novo = invoice.new_record?

        invoice.assign_attributes(
          order_id: order_id,

          number: nota[:numero],

          series: nota[:serie],

          access_key: nota[:chave_acesso],

          issued_at: nota[:data_emissao],

          total_amount: nota[:valor],

          status: situacao_de(nota),

          operation_type: operacao,

          metadata: (invoice.metadata || {}).merge(
            "origem" => "tiny",
            "numero_ecommerce" => nota[:numero_ecommerce],
            "situacao_tiny" => nota[:descricao_situacao],
            # O comprador vem junto porque é contra ELE que o título a receber
            # é lançado no OMIE — não contra o marketplace. Sem guardar aqui,
            # criar o título exigiria reler a nota no Tiny.
            "comprador_nome" => nota[:cliente_nome],
            "comprador_documento" => nota[:cliente_documento],
            # De qual marketplace a nota veio.
            #
            # Fica NA NOTA, e não só no pedido: nota sem pedido vinculado é
            # justamente o caso em que ninguém sabia responder de onde ela era,
            # e o pedido pode ser apagado com a conta sem levar a nota junto.
            "plataforma" => conta_da_nota&.platform,
            "sincronizado_em" => Time.current
          ).compact
        )

        # Nota recusada no envio ao OMIE volta para a fila quando o dado que
        # causou a recusa muda — valor preenchido, CPF corrigido. É a via de
        # volta: sem ela, corrigir no Tiny não adiantaria nada, porque a nota
        # continuaria marcada aqui.
        resumo[:reabertas] += 1 if invoice.liberar_recusa_se_mudou!

        invoice.save!

        resumo[novo ? :criadas : :atualizadas] += 1

        invoice
      end

      def operacao = @devolucoes ? :refund : :sale

      # Sem isto a NF ficaria solta: são estes vínculos que permitem ir do
      # repasse até o número da nota na hora de conciliar.
      def vincular_lancamentos!(invoice, order_id)
        atualizados =
          FinancialEntry
            .where(tenant_id: tenant.id, order_id: order_id, invoice_id: nil)
            .update_all(invoice_id: invoice.id, updated_at: Time.current)

        atualizados += ReceivableUnit
                         .where(tenant_id: tenant.id, order_id: order_id, invoice_id: nil)
                         .update_all(invoice_id: invoice.id, updated_at: Time.current)

        resumo[:vinculados] += atualizados
      end

      def situacao_de(nota)
        descricao = nota[:descricao_situacao].to_s

        SITUACOES.each { |padrao, status| return status if descricao.match?(padrao) }

        :issued
      end
    end
  end
end
