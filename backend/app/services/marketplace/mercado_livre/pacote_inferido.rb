module Marketplace
  module MercadoLivre
    # Descobre o pacote de uma venda quando o Mercado Livre não informa o
    # `pack_id`.
    #
    # A nota fiscal do pacote existe no nosso banco, pendurada num pedido cujo
    # id é o do PACOTE — criado pelo InvoiceSync a partir da própria nota. O
    # que falta é ligar a venda a ela, e o Mercado Livre não dá o caminho:
    # medido em amostra, ele devolve `pack_id` nulo em cerca de 40% dos casos
    # cuja nota está justamente sob um pacote.
    #
    # O COMPRADOR é o que identifica. Valor e data não servem: a loja vende o
    # mesmo modelo por R$ 184,65 em cinco canais, e qualquer venda casa com
    # dezenas de notas — foi o que a primeira tentativa devolveu, coincidência
    # pura.
    #
    # A regra é deliberadamente covarde: só aceita quando existe UMA nota
    # daquele comprador na janela. Comprador que voltou na mesma semana é
    # descartado em vez de chutado — um vínculo errado põe a nota da venda A no
    # dinheiro da venda B, e isso é pior do que venda sem nota.
    class PacoteInferido
      # Da liberação do dinheiro para trás. A nota é emitida na venda e o
      # Mercado Livre segura o valor por semanas.
      RECUO = 45

      # Pequena folga para frente: nota emitida no mesmo dia da liberação de
      # uma venda antiga acontece.
      FOLGA = 5

      Resultado = Struct.new(:pack_id, :motivo, keyword_init: true)

      def initialize(tenant:, client:)
        @tenant = tenant

        @client = client
      end

      # => Resultado com `pack_id` preenchido, ou com o motivo de não ter dado.
      def para(unidade)
        pedido = unidade.order

        return Resultado.new(motivo: :sem_pedido) if pedido.blank?

        documento = documento_do_comprador(pedido.external_id)

        return Resultado.new(motivo: :sem_documento) if documento.blank?

        candidatas = notas_do_comprador(documento, unidade)

        return Resultado.new(motivo: :nenhuma_nota) if candidatas.empty?

        # Mais de uma nota do mesmo comprador na janela: não dá para saber qual
        # é desta venda, e escolher seria inventar.
        return Resultado.new(motivo: :ambiguo) if candidatas.size > 1

        chave = candidatas.first.metadata.to_h["numero_ecommerce"].to_s

        return Resultado.new(motivo: :chave_vazia) if chave.blank?

        # A nota já está sob o número deste pedido: não é caso de pacote, e o
        # vínculo direto deveria ter pego. Devolver isto como pacote criaria um
        # `pack_id` apontando para o próprio pedido.
        return Resultado.new(motivo: :mesma_chave) if chave == pedido.external_id

        # A chave precisa ser de um PACOTE, e não de outra venda do mesmo
        # comprador.
        #
        # Este é o falso positivo que a medição não pegava: ela rodou sobre
        # vendas cuja nota EXISTE, então nunca encontrou o caso em que a venda
        # não tem nota e o comprador tem uma só, de outra compra. Aplicada na
        # população real, dois dos três primeiros palpites apontaram para outro
        # pedido dele.
        #
        # O teste é de dado, não de formato: pacote é um registro que nasceu da
        # nota e nunca recebeu dinheiro. Pedido de verdade tem recebível
        # próprio — e adotá-lo como pacote poria a nota de uma venda no
        # dinheiro de outra.
        return Resultado.new(motivo: :outra_venda) unless pacote?(chave)

        Resultado.new(pack_id: chave, motivo: :ok)
      end

      private

      attr_reader :tenant, :client

      # Um pacote não é uma venda: ele existe no nosso banco porque a nota o
      # criou, e nunca teve recebível nem lançamento.
      def pacote?(chave)
        candidato = Order.find_by(tenant_id: tenant.id, external_id: chave)

        return false if candidato.blank?

        ReceivableUnit.where(tenant_id: tenant.id, order_id: candidato.id).none? &&
          FinancialEntry.where(tenant_id: tenant.id, order_id: candidato.id).none?
      end

      def notas_do_comprador(documento, unidade)
        fim = (unidade.expected_on || Date.current) + FOLGA

        Invoice
          .where(tenant_id: tenant.id, operation_type: :sale)
          .where.not(status: :cancelled)
          .where(issued_at: (fim - RECUO - FOLGA)..fim)
          .where("regexp_replace(invoices.metadata->>'comprador_documento', '\\D', '', 'g') = ?", documento)
          .limit(3)
          .to_a
      end

      # O documento não vem mais dentro do pedido: o Mercado Livre o mantém no
      # endpoint de dados fiscais, que é de onde o vendedor tira para emitir a
      # nota.
      def documento_do_comprador(external_id)
        [ client.order_raw(external_id), client.billing_info(external_id) ]
          .compact
          .filter_map { |payload| procurar_documento(payload) }
          .first
      rescue StandardError
        nil
      end

      # Varredura em profundidade, e não caminhos fixos: o campo muda de lugar
      # conforme o tipo de venda, e três caminhos conhecidos já devolveram
      # "não tem" oito vezes seguidas para pedidos que tinham comprador.
      def procurar_documento(no)
        case no
        when Hash
          no.each do |chave, valor|
            if chave.to_s.match?(/doc_number|\Anumber\z|cpf|cnpj/i)
              limpo = valor.to_s.gsub(/\D/, "")

              return limpo if limpo.length.in?([ 11, 14 ])
            end

            achado = procurar_documento(valor)

            return achado if achado
          end
        when Array
          no.each do |item|
            achado = procurar_documento(item)

            return achado if achado
          end
        end

        nil
      end
    end
  end
end
