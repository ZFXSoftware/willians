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
        lancamentos: ligar!(FinancialEntry),
        recebiveis: ligar!(ReceivableUnit)
      }
    end

    private

    attr_reader :tenant

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
