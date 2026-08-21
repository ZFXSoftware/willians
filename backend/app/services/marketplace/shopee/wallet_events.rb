module Marketplace
  module Shopee
    # Converte as movimentações da carteira (get_wallet_transaction_list) em
    # lançamentos.
    #
    # CUIDADO COM DUPLICIDADE. A carteira contém `ESCROW_VERIFIED_ADD`: é o
    # escrow do pedido entrando no saldo. Esse mesmo dinheiro já foi
    # decomposto em venda e taxas por EscrowEvents. Ingerir os dois contaria a
    # venda duas vezes e dobraria o saldo.
    #
    # Então a carteira entra só com o que o escrow NÃO cobre: o saque para o
    # banco, os ajustes fora de pedido e as cobranças de anúncio e afiliado.
    # Tipo desconhecido é contado, não engolido.
    #
    # Campos e tipos conferidos na referência da API v2 (2026-08-21).
    class WalletEvents
      PLATFORM = "shopee".freeze

      # Já contabilizado pelo escrow — ver acima.
      DO_ESCROW = %w[
        ESCROW_VERIFIED_ADD
        ESCROW_VERIFIED_MINUS
        FAST_ESCROW_DISBURSE
        FAST_ESCROW_DISBURSE_REMAIN
        FAST_ESCROW_DEDUCT
      ].freeze

      # O saque: dinheiro saindo da carteira para o banco (briefing 2.7).
      #
      # Só o CONCLUÍDO vira lançamento. O criado é uma reserva que ainda pode
      # ser cancelada, e contar os dois lançaria o saque em dobro.
      SAQUES = {
        "WITHDRAWAL_COMPLETED" => { tipo: :settlement, direcao: :debit, rotulo: "Saque para o banco" },
        "WITHDRAWAL_CANCELLED" => { tipo: :adjustment, direcao: :credit, rotulo: "Saque cancelado" }
      }.freeze

      RESERVA_DE_SAQUE = "WITHDRAWAL_CREATED".freeze

      TIPOS = {
        "ADJUSTMENT_ADD" => { tipo: :adjustment, direcao: :credit, rotulo: "Ajuste a favor" },
        "ADJUSTMENT_MINUS" => { tipo: :adjustment, direcao: :debit, rotulo: "Ajuste a débito" },
        "ADJUSTMENT_CENTER_ADD" => { tipo: :adjustment, direcao: :credit, rotulo: "Ajuste da central" },
        "ADJUSTMENT_CENTER_DEDUCT" => { tipo: :adjustment, direcao: :debit, rotulo: "Ajuste da central" },
        "FBS_ADJUSTMENT_ADD" => { tipo: :adjustment, direcao: :credit, rotulo: "Ajuste de fulfillment" },
        "FBS_ADJUSTMENT_MINUS" => { tipo: :adjustment, direcao: :debit, rotulo: "Ajuste de fulfillment" },
        "FSF_COST_PASSING_DEDUCT" => { tipo: :fee, direcao: :debit, rotulo: "Custo de frete repassado" },
        "PAID_ADS_CHARGE" => { tipo: :fee, direcao: :debit, rotulo: "Anúncios" },
        "PAID_ADS_REFUND" => { tipo: :adjustment, direcao: :credit, rotulo: "Estorno de anúncios" },
        "AFFILIATE_ADS_SELLER_FEE" => { tipo: :fee, direcao: :debit, rotulo: "Taxa de afiliado" },
        "AFFILIATE_ADS_SELLER_FEE_REFUND" => { tipo: :adjustment, direcao: :credit, rotulo: "Estorno de afiliado" },
        "AFFILIATE_FEE_DEDUCT" => { tipo: :fee, direcao: :debit, rotulo: "Marketing de afiliado" },
        "PERCEPTION_VAT_TAX_DEDUCT" => { tipo: :fee, direcao: :debit, rotulo: "VAT retido" },
        "PERCEPTION_TURNOVER_TAX_DEDUCT" => { tipo: :fee, direcao: :debit, rotulo: "Imposto sobre faturamento" }
      }.merge(SAQUES).freeze

      # Movimentação que ainda pode não acontecer não entra no razão.
      SO_CONCLUIDAS = %w[COMPLETED].freeze

      attr_reader :ignorados,
                  :pendentes

      def initialize(transacoes)
        @transacoes = Array(transacoes)

        @ignorados = Hash.new(0)

        @pendentes = 0
      end

      def call
        @transacoes.filter_map { |transacao| evento(transacao) }
      end

      # Saldo declarado pela Shopee, para o espelho do briefing 2.4. É o
      # current_balance da movimentação mais recente.
      def saldo
        recente = @transacoes
                    .select { |t| t["current_balance"].present? }
                    .max_by { |t| t["create_time"].to_i }

        return if recente.blank?

        { valor: decimal(recente["current_balance"]), em: hora(recente["create_time"]) }
      end

      private

      def evento(transacao)
        tipo = transacao["transaction_type"].to_s.strip.upcase

        return if DO_ESCROW.include?(tipo)

        # A criação do saque é reserva; o concluído é que move o dinheiro.
        return if tipo == RESERVA_DE_SAQUE

        regra = TIPOS[tipo]

        unless regra
          @ignorados[tipo] += 1

          return
        end

        status = transacao["status"].to_s.strip.upcase

        unless SO_CONCLUIDAS.include?(status)
          @pendentes += 1

          return
        end

        valor = decimal(transacao["amount"]).abs

        return if valor.zero?

        montar(transacao, regra, valor, tipo)
      end

      def montar(transacao, regra, valor, tipo)
        ocorrido = hora(transacao["create_time"])

        # `money_flow` é a palavra final sobre a direção: a documentação diz
        # que MONEY_IN é entrada e MONEY_OUT é saída, e ela sabe melhor que a
        # nossa tabela quando os dois discordam.
        direcao = direcao_de(transacao) || regra[:direcao]

        {
          external_id: identificador(transacao, tipo),
          platform: PLATFORM,
          entry_type: regra[:tipo],
          direction: direcao,
          amount: valor,
          currency: "BRL",
          occurred_at: ocorrido,
          available_on: ocorrido&.to_date,
          external_order_id: transacao["order_sn"].to_s.presence,
          description: transacao["reason"].presence || regra[:rotulo],
          metadata: {
            "transaction_type" => tipo,
            "withdrawal_id" => transacao["withdrawal_id"],
            "refund_sn" => transacao["refund_sn"].presence,
            "saldo_apos" => transacao["current_balance"]
          }.compact
        }
      end

      def direcao_de(transacao)
        case transacao["money_flow"].to_s.strip.upcase
        when "MONEY_IN" then :credit
        when "MONEY_OUT" then :debit
        end
      end

      # A carteira não tem um id de transação próprio. O saque tem
      # withdrawal_id; o resto se identifica por tipo, instante e pedido, que
      # juntos não se repetem.
      def identificador(transacao, tipo)
        chave = transacao["withdrawal_id"].presence ||
                [transacao["order_sn"], transacao["create_time"]].compact.join("-")

        "SHOPEE-WALLET-#{tipo}-#{chave}"
      end

      def hora(timestamp)
        return if timestamp.blank?

        Time.zone.at(timestamp.to_i)
      rescue TypeError, RangeError
        nil
      end

      def decimal(valor)
        return BigDecimal("0") if valor.nil?

        BigDecimal(valor.to_s)
      rescue ArgumentError
        BigDecimal("0")
      end
    end
  end
end
