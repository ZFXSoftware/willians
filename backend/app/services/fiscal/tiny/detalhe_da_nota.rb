module Fiscal
  module Tiny
    # Lê a nota COMPLETA no Tiny e guarda o que ela declara: quem intermediou a
    # venda e os valores fiscais.
    #
    # Chamava-se IntermediadorSync e guardava só o intermediador, descartando o
    # resto de uma resposta que tem 57 campos — o mesmo desperdício do relatório
    # de liberações, onde guardávamos 4 colunas de 23 e a explicação de uma
    # divergência de meses estava numa das descartadas.
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
    class DetalheDaNota
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

            # Recusa DEFINITIVA sai da fila; recusa temporária não.
            #
            # "Nota Fiscal não localizada" não muda de resposta: a nota não está
            # no Tiny sob o id que guardamos, e reperguntar a cada cinco minutos
            # é cota jogada fora — o mesmo desperdício das notas recusadas pelo
            # OMIE, que já corrigimos uma vez.
            #
            # "API Bloqueada" é o oposto: é excesso de acesso, e a resposta muda
            # sozinha em minutos. Marcar essa como definitiva perderia a nota
            # para sempre por um erro que ia passar.
            if definitiva?(e)
              marcar_recusa!(nota, e.message)

              resumo[:recusadas] = resumo[:recusadas].to_i + 1
            end

            Rails.logger.warn "[DetalheDaNota] NF #{nota.number}: #{e.class} #{e.message}"
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
      # O Tiny não muda de resposta para estas.
      NAO_LOCALIZADA = /não localizada|nao localizada|not found/i

      def definitiva?(erro)
        erro.is_a?(V2Client::ApiError) && erro.message.to_s.match?(NAO_LOCALIZADA)
      end

      # Fica no metadata, visível, em vez de a nota sumir da fila sem rastro.
      def marcar_recusa!(nota, mensagem)
        nota.update!(metadata: (nota.metadata || {}).merge(
          "tiny_recusa" => { "em" => Time.current, "motivo" => mensagem.to_s.truncate(200) }
        ))
      rescue StandardError => e
        Rails.logger.error "[DetalheDaNota] não consegui marcar a recusa da NF #{nota.number}: #{e.message}"
      end

      def pendentes
        Invoice
          .where(tenant_id: tenant.id)
          # Falta o intermediador OU faltam os valores fiscais.
          #
          # As notas já lidas têm intermediador e não têm `fiscal`: sem a
          # segunda condição elas nunca seriam reperguntadas e o dado fiscal
          # valeria só para nota nova. É uma releitura de toda a base, uma
          # consulta por nota, mas em lotes dentro do ciclo — ninguém segura
          # terminal aberto, e é a mesma travessia que o intermediador já fez.
          # Falta o intermediador, faltam os valores fiscais, ou o OMIE recusou
          # a nota por falta de comprador — e o comprador está na nota completa
          # do Tiny, que esta mesma consulta traz.
          #
          # Só as recusadas, e não toda nota sem comprador: venda de balcão
          # legitimamente não tem, e reperguntar por ela seria a fila infinita
          # que as outras condições deste método existem para evitar.
          .where("invoices.metadata->'intermediador' IS NULL " \
                 "OR invoices.metadata->'fiscal' IS NULL " \
                 "OR (invoices.metadata->>'comprador_documento' IS NULL " \
                 "AND invoices.metadata->'omie_recusa'->>'motivo' = 'sem_comprador')")
          # A que o Tiny já disse que não conhece fica fora da fila.
          .where("invoices.metadata->'tiny_recusa' IS NULL")
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
          "intermediador" => { "nome" => intermediador["nome"], "cnpj" => intermediador["cnpj"] },
          "fiscal" => fiscal_de(detalhe),
          **comprador_de(detalhe, nota)
        ))

        resumo[:lidas] += 1

        resumo[:com_desconto] = resumo[:com_desconto].to_i + 1 if detalhe["valor_desconto"].to_d.positive?

        resumo[:com_st] = resumo[:com_st].to_i + 1 if detalhe["valor_icms_st"].to_d.positive?

        resumo[:canais][intermediador["nome"].presence || "(não informado)"] += 1
      end

      # O comprador, quando ainda não o temos.
      #
      # É contra ELE que o título a receber é lançado no OMIE — não contra o
      # marketplace. A listagem por período nem sempre traz, e a nota completa
      # traz: esta consulta já está sendo feita, e descartar o cliente dela
      # deixava 32 notas recusadas para sempre.
      #
      # Não sobrescreve o que já existe: o que veio na importação é o que valeu.
      def comprador_de(detalhe, nota)
        return {} if nota.metadata.to_h["comprador_documento"].present?

        cliente = detalhe["cliente"] || {}

        documento = cliente["cpf_cnpj"].presence || cliente["cnpj_cpf"].presence

        return {} if documento.blank?

        {
          "comprador_nome" => cliente["nome"].to_s.strip.presence,
          "comprador_documento" => documento
        }
      end

      # O que a nota declara, e só isso.
      #
      # Nada do comprador entra aqui: nome, CPF e endereço vêm na mesma resposta
      # e não têm por que ser copiados para dentro da nossa nota.
      #
      # `valor_desconto` é o campo que explica a diferença entre a venda no
      # marketplace e a nota: medido em quatro notas, a venda é igual ao
      # `valor_produtos` e a nota sai com o desconto abatido.
      #
      # `valor_icms_st` acima de zero é ICMS já pago por substituição — imposto
      # recolhido antes, que não deve ser tributado de novo. É o que a
      # conciliação fiscal precisa achar sem baixar o XML de cada nota.
      #
      # `regime_tributario` 1 é Simples Nacional, onde a nota não destaca ICMS
      # nem PIS/COFINS e o tributo sai no DAS. Guardado por NOTA porque o
      # regime da empresa pode mudar no meio do período, e aí o histórico
      # precisa dizer qual valia quando cada nota saiu.
      def fiscal_de(detalhe)
        {
          "regime_tributario" => detalhe["regime_tributario"],
          "tipo_nota" => detalhe["tipo_nota"],
          "natureza_operacao" => detalhe["natureza_operacao"],
          "valor_produtos" => detalhe["valor_produtos"],
          "valor_desconto" => detalhe["valor_desconto"],
          "valor_frete" => detalhe["valor_frete"],
          "valor_outras" => detalhe["valor_outras"],
          "valor_nota" => detalhe["valor_nota"],
          "base_icms" => detalhe["base_icms"],
          "valor_icms" => detalhe["valor_icms"],
          "base_icms_st" => detalhe["base_icms_st"],
          "valor_icms_st" => detalhe["valor_icms_st"],
          "valor_ipi" => detalhe["valor_ipi"],
          "valor_issqn" => detalhe["valor_issqn"],
          # CFOP separa operação interna de interestadual, e venda de
          # devolução. NCM identifica o produto para fins de substituição
          # tributária. Um por item, sem repetir.
          "cfops" => itens_de(detalhe).filter_map { |item| item["cfop"].presence }.uniq,
          "ncms" => itens_de(detalhe).filter_map { |item| item["ncm"].presence }.uniq
        }
      end

      # O Tiny embrulha cada item num hash de uma chave.
      def itens_de(detalhe)
        Array(detalhe["itens"]).map do |item|
          item.is_a?(Hash) && item.values.first.is_a?(Hash) ? item.values.first : item
        end.select { |item| item.is_a?(Hash) }
      end
    end
  end
end
