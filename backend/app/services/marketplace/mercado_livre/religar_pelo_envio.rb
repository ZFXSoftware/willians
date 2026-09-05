module Marketplace
  module MercadoLivre
    # Reaproveita, SEM falar com o marketplace, o que ele já respondeu.
    #
    # `NotaDoEnvio` marca o pedido depois de perguntar, para não repetir duas
    # chamadas de API por venda a cada volta do ciclo. Mas a marca acabou
    # impedindo também o pareamento LOCAL — e esse não custa nada.
    #
    # A diferença importa porque o nosso banco muda: a nota que não existia
    # aqui quando perguntamos chega na importação seguinte do Tiny, e ninguém
    # voltava para ligá-la. É o mesmo defeito que já corrigimos entre nota e
    # dinheiro, agora entre a resposta do marketplace e a nota.
    class ReligarPeloEnvio
      def initialize(tenant:, dry_run: true)
        @tenant = tenant

        @dry_run = dry_run
      end

      def call
        resumo = Hash.new(0)

        resumo[:exemplos] = []

        pendentes.find_each { |unidade| processar(unidade, resumo) }

        resumo
      end

      # Vendas sem nota cujo pedido JÁ tem a resposta do marketplace guardada.
      def pendentes
        ReceivableUnit
          .where(tenant_id: tenant.id, invoice_id: nil)
          .joins(:order)
          .where("orders.metadata->'nota_do_envio' IS NOT NULL")
          .where("jsonb_typeof(orders.metadata->'nota_do_envio') = 'object'")
          .includes(:order)
      end

      private

      attr_reader :tenant, :dry_run

      def processar(unidade, resumo)
        dados = unidade.order.metadata["nota_do_envio"]

        nota = procurar(dados)

        return resumo[:sem_nota_aqui] += 1 if nota.blank?

        # Nota cancelada não é a nota da venda. Ligá-la desfaria o conserto de
        # `VinculoDeNotas#soltar_canceladas!`, que a solta a cada ciclo — as
        # duas regras ficariam brigando, uma ligando e a outra soltando.
        return resumo[:canceladas] += 1 if nota.status.to_s == "cancelled"

        resumo[:ligadas] += 1

        if resumo[:exemplos].size < 5
          resumo[:exemplos] << "pedido #{unidade.order.external_id} -> NF #{nota.number}/#{nota.series}"
        end

        return if dry_run

        unidade.update!(invoice_id: nota.id)

        # A chave que falta no nosso cadastro veio junto da resposta, e só
        # preenchemos o que está vazio: chave gravada é dado do documento.
        nota.update!(access_key: dados["chave"]) if nota.access_key.blank? && dados["chave"].present?
      end

      def procurar(dados)
        notas = Invoice.where(tenant_id: tenant.id)

        chave = dados["chave"].to_s.gsub(/\D/, "")

        if chave.present?
          pela_chave = notas.where("regexp_replace(COALESCE(access_key,''), '\\D', '', 'g') = ?", chave).first

          return pela_chave if pela_chave
        end

        numero = dados["numero"].to_s.sub(/\A0+/, "")

        return if numero.blank?

        notas
          .where("regexp_replace(COALESCE(number,''), '\\A0+', '') = ?", numero)
          .where(series: [ dados["serie"].to_s, dados["serie"].to_s.sub(/\A0+/, ""), nil ])
          .first
      end
    end
  end
end
