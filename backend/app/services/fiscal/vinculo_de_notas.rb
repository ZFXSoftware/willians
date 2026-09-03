module Fiscal
  # Liga a nota fiscal ao dinheiro que já entrou.
  #
  # O `InvoiceSync` liga no momento em que a NOTA é importada, e liga o que
  # existir naquele instante. Mas a ordem natural dos fatos é a oposta: a nota
  # é emitida no dia da venda e o dinheiro é liberado pelo marketplace duas
  # semanas depois. Quando a nota chega, não há recebível para ligar; quando o
  # recebível nasce, ninguém volta para procurar a nota.
  #
  # Resultado medido na base do cliente: 1349 vendas pagas, só 630 com nota
  # ligada — e 176 delas com a nota ali, no mesmo banco, com o número do pedido
  # batendo. Os 630 que funcionaram foram os que tiveram o Tiny importado
  # DEPOIS do extrato; o caminho normal falhava sempre.
  #
  # Isto fecha o elo pelo outro lado, e roda a cada volta do ciclo: qualquer
  # recebível ou lançamento que ganhe pedido depois é religado sozinho.
  class VinculoDeNotas
    def initialize(tenant:)
      @tenant = tenant
    end

    def call
      {
        soltas: soltar_canceladas!,
        lancamentos: ligar!(FinancialEntry),
        recebiveis: ligar!(ReceivableUnit),
        por_pacote: ligar_por_pacote!
      }
    end

    private

    attr_reader :tenant

    # Nota cancelada não é a nota da venda.
    #
    # Ela foi emitida, grudou no recebível, e depois foi cancelada no Tiny —
    # provavelmente com outra emitida no lugar. Nós continuávamos apontando
    # para a morta: o envio ao OMIE a ignorava (certo, ninguém manda nota
    # cancelada para a contabilidade) e a conciliação seguia esperando um
    # título que nunca vai existir, contando a venda como "sem título".
    #
    # Soltar é o que permite o religamento logo abaixo encontrar a substituta.
    def soltar_canceladas!
      canceladas = Invoice.where(tenant_id: tenant.id, status: :cancelled).select(:id)

      soltos = ReceivableUnit.where(tenant_id: tenant.id, invoice_id: canceladas)
                             .update_all(invoice_id: nil, updated_at: Time.current)

      soltos + FinancialEntry.where(tenant_id: tenant.id, invoice_id: canceladas)
                             .update_all(invoice_id: nil, updated_at: Time.current)
    end

    # A nota do PACOTE, para a venda que faz parte dele.
    #
    # Quando o comprador leva dois itens numa compra só, o Mercado Livre cria
    # um pack com id próprio. A nota fiscal é emitida para o PACOTE, então o
    # Tiny grava o id do pack em `numero_ecommerce` — enquanto o extrato e a
    # API de pedidos falam do pedido individual. Os dois números nunca se
    # encontram, e a venda fica sem nota para sempre.
    #
    # Medido na base do cliente: 543 vendas pagas sem nota, todas ausentes do
    # Tiny quando procuradas pelo número do pedido.
    #
    # O `pack_id` fica no metadata do pedido, gravado pelo VinculoDePedidos. O
    # InvoiceSync, ao importar a nota do pacote, criou um pedido com o id do
    # pack — é nele que a nota está pendurada.
    def ligar_por_pacote!
      linhas = ReceivableUnit.connection.exec_update(<<~SQL, "VinculoDeNotas.pacote", [ tenant.id, tenant.id ])
        UPDATE receivable_units AS alvo
        SET invoice_id = escolhida.id,
            updated_at = NOW()
        FROM orders AS pedido
        JOIN orders AS pacote
          ON pacote.tenant_id = pedido.tenant_id
         AND pacote.external_id = pedido.metadata->>'pack_id'
        JOIN LATERAL (
          SELECT id
          FROM invoices
          WHERE invoices.tenant_id = pacote.tenant_id
            AND invoices.order_id = pacote.id
            AND invoices.operation_type = 'sale'
            AND invoices.status <> 'cancelled'
          ORDER BY issued_at ASC, id ASC
          LIMIT 1
        ) AS escolhida ON TRUE
        WHERE pedido.tenant_id = $1
          AND pedido.metadata->>'pack_id' IS NOT NULL
          AND alvo.tenant_id = $2
          AND alvo.order_id = pedido.id
          AND alvo.invoice_id IS NULL
      SQL

      linhas.to_i
    end

    # Um UPDATE só, e não um por registro: são milhares de linhas e isto roda
    # a cada volta do ciclo.
    #
    # A nota escolhida é a de VENDA não cancelada mais antiga do pedido. Um
    # pedido pode ter mais de uma nota (complementar, reemissão), e pegar
    # qualquer uma faria o mesmo pedido casar com títulos diferentes conforme
    # a ordem do banco.
    def ligar!(modelo)
      linhas = modelo.connection.exec_update(<<~SQL, "VinculoDeNotas", [ tenant.id, tenant.id ])
        UPDATE #{modelo.table_name} AS alvo
        SET invoice_id = escolhida.id,
            updated_at = NOW()
        FROM (
          SELECT DISTINCT ON (order_id) order_id, id
          FROM invoices
          WHERE tenant_id = $1
            AND order_id IS NOT NULL
            AND operation_type = 'sale'
            AND status <> 'cancelled'
          ORDER BY order_id, issued_at ASC, id ASC
        ) AS escolhida
        WHERE alvo.tenant_id = $2
          AND alvo.order_id = escolhida.order_id
          AND alvo.invoice_id IS NULL
      SQL

      linhas.to_i
    end
  end
end
