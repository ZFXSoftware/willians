module Marketplace
  module MercadoLivre
    # Grava o pacote inferido nos pedidos cuja venda ficou sem nota fiscal.
    #
    # O Mercado Livre devolve `pack_id` nulo em boa parte das vendas cuja nota
    # está justamente sob um pacote. Medido contra 25 vendas de pacote
    # CONHECIDO: 18 inferências, 18 certas, 0 erradas, 7 recusadas por prudência.
    #
    # A procedência fica gravada junto. `pack_id_origem` separa o que o
    # marketplace informou do que nós deduzimos — sem isso, daqui a três meses
    # ninguém distingue medição de palpite, e uma heurística que errasse 2%
    # viraria verdade permanente no banco.
    #
    # Nunca sobrescreve pacote vindo da API: o dado informado vence o deduzido,
    # sempre.
    class PacotesInferidos
      # Duas chamadas ao Mercado Livre por venda, com pausa. Cabe na volta do
      # ciclo sem atrasar a conciliação, e o que sobra vai na próxima.
      LOTE_PADRAO = 40

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

          resultado = inferidor.para(unidade)

          if resultado.pack_id.blank?
            resumo[resultado.motivo] += 1

            next
          end

          resumo[:inferidos] += 1

          if resumo[:exemplos].size < 5
            resumo[:exemplos] << "#{unidade.order.external_id} -> pacote #{resultado.pack_id}"
          end

          gravar!(unidade.order, resultado.pack_id) unless dry_run
        rescue StandardError => e
          resumo[:falhas] += 1

          Rails.logger.warn "[PacotesInferidos] #{unidade.order&.external_id}: #{e.class} #{e.message}"
        end

        resumo
      end

      # Vendas sem nota fiscal cujo pedido ainda não tem pacote nenhum.
      #
      # Pedido que já tem `pack_id` está resolvido ou já foi tentado; repetir
      # seria gastar duas chamadas ao Mercado Livre por volta do ciclo para
      # chegar na mesma resposta.
      def pendentes
        ReceivableUnit
          .where(tenant_id: tenant.id, platform_account_id: platform_account.id, invoice_id: nil)
          .joins(:order)
          .where("orders.metadata->>'pack_id' IS NULL")
          .where("orders.metadata->>'pacote_sem_resposta' IS NULL")
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

      def inferidor
        @inferidor ||= PacoteInferido.new(tenant: tenant, client: client)
      end

      def gravar!(pedido, pack_id)
        pedido.update!(metadata: (pedido.metadata || {}).merge(
          "pack_id" => pack_id,
          # A marca que separa medição de dedução. O `VinculoDeNotas` não
          # distingue os dois — e não precisa —, mas quem for auditar depois,
          # sim.
          "pack_id_origem" => "inferido",
          "pack_id_inferido_em" => Time.current
        ))
      end
    end
  end
end
