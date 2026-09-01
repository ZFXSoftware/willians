module Fiscal
  module Tiny
    # Lê, na NF-e, quem intermediou a venda, e grava na nossa nota.
    #
    # É o que permite saber de qual canal veio cada nota. Sem isso o
    # InvoiceSync cai na regra antiga — "só existe uma conta ativa, deve ser
    # essa" —, que numa amostra de 40 notas do cliente pôs 23 vendas de
    # Shopee, Amazon, Magalu e TikTok na conciliação do Mercado Livre.
    #
    # O campo só vem na nota COMPLETA: uma consulta por nota, com pausa, porque
    # o Tiny limita requisições. Milhares de notas dão mais de uma hora — tempo
    # demais para uma requisição de navegador e tempo demais para um terminal
    # que cai por inatividade.
    #
    # Por isso roda em LOTES dentro do ciclo automático, e não numa execução
    # longa: cada volta lê um pedaço, o progresso fica gravado nota a nota, e
    # parar no meio não perde nada.
    class IntermediadorSync
      # Um minuto por volta.
      #
      # O ciclo de conciliação é agendado a cada cinco minutos, e esta leitura
      # roda dentro dele: um lote grande atrasaria a conciliação e as voltas
      # começariam a se sobrepor. Com 60, milhares de notas se resolvem em umas
      # poucas horas, sozinhas, e ninguém precisa segurar um terminal aberto.
      LOTE_PADRAO = 60

      PAUSA_PADRAO = 1.0

      def initialize(tenant:, client: nil, limite: LOTE_PADRAO, pausa: PAUSA_PADRAO)
        @tenant = tenant

        @client = client

        @limite = limite

        @pausa = pausa
      end

      def call
        resumo = { lidas: 0, falhas: 0, canais: Hash.new(0) }

        Current.with_tenant(tenant) do
          resumo[:pendentes_antes] = pendentes.count

          next resumo if resumo[:pendentes_antes].zero?

          pendentes.limit(limite).each do |nota|
            processar(nota, resumo)
          rescue StandardError => e
            resumo[:falhas] += 1

            Rails.logger.warn "[IntermediadorSync] NF #{nota.number}: #{e.class} #{e.message}"
          end
        end

        resumo[:pendentes] = [ resumo[:pendentes_antes].to_i - resumo[:lidas], 0 ].max

        resumo
      end

      # Quantas ainda não foram perguntadas ao Tiny.
      #
      # A checagem é pela CHAVE, e não pelo nome: nota cujo Tiny respondeu "não
      # sei" fica com o hash presente e o nome nulo. Sem essa distinção ela
      # seria reperguntada a cada volta, para sempre — o mesmo defeito das
      # notas recusadas no envio ao OMIE.
      def pendentes
        Invoice
          .where(tenant_id: tenant.id)
          .where("invoices.metadata->'intermediador' IS NULL")
          .order(issued_at: :desc)
      end

      private

      attr_reader :tenant, :limite, :pausa

      def client
        @client ||= V2Client.new
      end

      def processar(nota, resumo)
        sleep(pausa) if pausa.to_f.positive?

        detalhe = client.obter_nota(nota.external_id)

        if detalhe.blank?
          resumo[:falhas] += 1

          return
        end

        intermediador = detalhe["intermediador"] || {}

        # `|| {}`: a coluna aceita nulo, e nota criada por outro caminho chega
        # sem metadata nenhum. Sem isto o merge estoura e a nota é contada como
        # falha do Tiny — que é onde ninguém iria procurar o defeito.
        nota.update!(metadata: (nota.metadata || {}).merge(
          "intermediador" => { "nome" => intermediador["nome"], "cnpj" => intermediador["cnpj"] }
        ))

        resumo[:lidas] += 1

        resumo[:canais][intermediador["nome"].presence || "(não informado)"] += 1
      end
    end
  end
end
