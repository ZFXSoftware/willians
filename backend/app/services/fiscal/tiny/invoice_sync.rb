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

        criar_pedidos_faltantes!(refs)

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
      def criar_pedidos_faltantes!(refs)
        conta = conta_da_nota

        return resumo[:sem_plataforma] += refs.size if conta.blank?

        conhecidos = Order.where(tenant_id: tenant.id, external_id: refs).pluck(:external_id).to_set

        faltando = refs.reject { |ref| conhecidos.include?(ref) }

        return if faltando.empty?

        agora = Time.current

        Order.insert_all(
          faltando.map do |ref|
            {
              tenant_id: tenant.id,
              platform_account_id: conta.id,
              platform: conta.platform,
              external_id: ref,
              status: "pending",
              currency: "BRL",
              metadata: { "origem" => "tiny_invoice_sync" },
              created_at: agora,
              updated_at: agora
            }
          end,
          unique_by: :idx_orders_unique
        )

        resumo[:pedidos_criados] += faltando.size
      end

      # A nota do Tiny não diz de qual marketplace ela é. Com uma conta só na
      # empresa, não há ambiguidade. Com várias, atribuir seria chute — e um
      # pedido no marketplace errado estragaria a conciliação daquela conta.
      def conta_da_nota
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
