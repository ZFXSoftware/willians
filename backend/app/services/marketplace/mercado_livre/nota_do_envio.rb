module Marketplace
  module MercadoLivre
    # Liga a venda à nota fiscal pela CHAVE que o Mercado Livre guarda.
    #
    # Foi a última fonte que sobrou, depois de quatro tentativas: a SEFAZ
    # recusa entregar ao emitente as próprias notas (cStat 641), o SPED não
    # existe para empresa do Simples, o Tiny só sabe do que ele emitiu, e a
    # fila de DF-e está disputada com outro consumidor.
    #
    # O marketplace exige a nota para despachar e guarda a chave em
    # `/shipments/{id}/invoice_data`. É a única fonte que conhece a VENDA e o
    # DOCUMENTO ao mesmo tempo.
    #
    # E o casamento é por IDENTIDADE, não por semelhança: chave de acesso é
    # única. Isso substitui, com vantagem, a inferência por CPF e valor — que
    # recusava 28% dos casos por prudência e ainda assim podia errar.
    class NotaDoEnvio
      # Duas chamadas por venda (pedido e envio), com pausa. Cabe na volta do
      # ciclo sem atrasar a conciliação.
      LOTE_PADRAO = 30

      PAUSA_PADRAO = 1.0

      def initialize(tenant:, platform_account:, client: nil, limite: LOTE_PADRAO,
                     pausa: PAUSA_PADRAO, dry_run: false)
        @tenant = tenant

        @platform_account = platform_account

        @client = client

        @limite = limite

        @pausa = pausa

        @dry_run = dry_run
      end

      def call
        resumo = Hash.new(0)

        resumo[:exemplos] = []

        pendentes.limit(limite).each do |unidade|
          sleep(pausa) if pausa.to_f.positive?

          processar(unidade, resumo)
        rescue StandardError => e
          resumo[:falhas] += 1

          Rails.logger.warn "[NotaDoEnvio] #{unidade.order&.external_id}: #{e.class} #{e.message}"
        end

        resumo
      end

      # Vendas sem nota cujo pedido ainda não foi perguntado ao marketplace.
      #
      # A marca evita repetir a consulta a cada volta do ciclo para um pedido
      # que já respondeu — duas chamadas por venda, para sempre, seria o mesmo
      # desperdício das notas recusadas que ficavam na fila.
      def pendentes
        ReceivableUnit
          .where(tenant_id: tenant.id, platform_account_id: platform_account.id, invoice_id: nil)
          .joins(:order)
          .where("orders.metadata->>'nota_do_envio' IS NULL")
          .includes(:order)
          .order(expected_on: :desc)
      end

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

        envio = client.bruto("/orders/#{pedido.external_id}").dig("shipping", "id")

        return resumo[:sem_envio] += 1 if envio.blank?

        dados = client.invoice_data(envio)

        if dados.blank?
          marcar!(pedido, "sem nota no marketplace")

          return resumo[:sem_nota_no_ml] += 1
        end

        nota = procurar(dados[:chave])

        if nota.blank?
          # Duas situações opostas, e a chave sozinha não as separa: ou a nota
          # não está no nosso banco, ou está e a CHAVE dela é que não bate.
          #
          # A segunda seria defeito nosso — chave ausente ou gravada diferente
          # — e ficaria escondida atrás de "não temos essa nota", que manda
          # procurar no lugar errado.
          pelo_numero = procurar_por_numero(dados)

          marcar!(pedido, dados)

          if pelo_numero
            # O marketplace diz, com autoridade, que ESTE envio saiu com ESTA
            # nota. Número e série de uma fonte assim identificam tanto quanto
            # a chave — e a chave que ele devolve é a peça que falta no nosso
            # cadastro.
            #
            # Medido: 13 de 30 notas do cliente estão sem `access_key`, porque
            # a importação do Tiny não a trouxe. Casar só por chave deixaria
            # essas de fora para sempre, por falta de um dado que temos em mãos.
            resumo[:ligadas_pelo_numero] += 1

            if resumo[:exemplos].size < 5
              resumo[:exemplos] << "pedido #{pedido.external_id} -> NF #{pelo_numero.number} " \
                                   "(chave preenchida a partir do marketplace)"
            end

            unless dry_run
              unidade.update!(invoice_id: pelo_numero.id)

              # Só preenche o que está vazio: chave gravada é dado do documento
              # e não se sobrescreve com informação de terceiro.
              pelo_numero.update!(access_key: dados[:chave]) if pelo_numero.access_key.blank?
            end
          else
            resumo[:nao_temos] += 1

            if resumo[:exemplos].size < 5
              resumo[:exemplos] << "pedido #{pedido.external_id}: NF #{dados[:numero]}/#{dados[:serie]} não está no nosso banco"
            end
          end

          return
        end

        resumo[:ligadas] += 1

        if resumo[:exemplos].size < 5
          resumo[:exemplos] << "pedido #{pedido.external_id} -> NF #{nota.number}"
        end

        return if dry_run

        unidade.update!(invoice_id: nota.id)

        marcar!(pedido, dados)
      end

      # Chave de acesso é única: o casamento é exato.
      def procurar(chave)
        Invoice
          .where(tenant_id: tenant.id)
          .where("regexp_replace(COALESCE(access_key, ''), '\\D', '', 'g') = ?", chave)
          .first
      end

      # O Tiny grava o número com zeros à esquerda ("044613") e o marketplace
      # devolve sem ("44613"). Comparar cru faria a mesma nota parecer ausente.
      def procurar_por_numero(dados)
        numero = dados[:numero].to_s.sub(/\A0+/, "")

        return if numero.blank?

        Invoice
          .where(tenant_id: tenant.id)
          .where("regexp_replace(COALESCE(number, ''), '\\A0+', '') = ?", numero)
          .where(series: [ dados[:serie].to_s, dados[:serie].to_s.sub(/\A0+/, ""), nil ])
          .first
      end

      def marcar!(pedido, dados)
        return if dry_run

        pedido.update!(metadata: (pedido.metadata || {}).merge("nota_do_envio" => dados))
      end
    end
  end
end
