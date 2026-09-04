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
          # A nota existe e nós não a temos. Guardar o que o marketplace disse
          # é o que permite ir buscá-la depois — e é resposta, não fracasso.
          marcar!(pedido, dados)

          resumo[:nao_temos] += 1

          if resumo[:exemplos].size < 5
            resumo[:exemplos] << "pedido #{pedido.external_id}: NF #{dados[:numero]}/#{dados[:serie]} não está no nosso banco"
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

      def marcar!(pedido, dados)
        return if dry_run

        pedido.update!(metadata: (pedido.metadata || {}).merge("nota_do_envio" => dados))
      end
    end
  end
end
