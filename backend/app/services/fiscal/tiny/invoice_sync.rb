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

      def initialize(tenant:, reader: nil)
        @tenant = tenant

        @reader = reader || Reader.new

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

          resumo
        end
      end

      private

      attr_reader :tenant,
                  :reader,
                  :resumo

      # Uma consulta só para todos os pedidos referenciados nas notas.
      def mapear_pedidos(notas)
        refs = notas.filter_map { |n| n[:numero_ecommerce] }.uniq

        return {} if refs.empty?

        Order
          .where(tenant_id: tenant.id, external_id: refs)
          .pluck(:external_id, :id)
          .to_h
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
            "sincronizado_em" => Time.current
          )
        )

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
