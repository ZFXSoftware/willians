module Marketplace
  module Shopee
    # Converte o detalhe financeiro de um pedido (get_escrow_detail) em
    # lançamentos do nosso razão.
    #
    # A documentação publica a FÓRMULA do escrow_amount — o líquido que o
    # vendedor recebe. Transcrevê-la aqui dá duas coisas de uma vez: a lista
    # exata do que é crédito e do que é dedução, e um jeito de o código
    # conferir a si mesmo. Se a nossa decomposição não somar o escrow_amount
    # que a Shopee informou, o mapeamento está errado — e é melhor gritar do
    # que gravar valor errado na contabilidade.
    #
    # Campos conferidos na referência da API v2 (lida em 2026-08-21).
    class EscrowEvents
      PLATFORM = "shopee".freeze

      # Centavos de arredondamento entre a nossa soma e a da Shopee.
      TOLERANCIA = BigDecimal("0.05")

      # Entram a favor do vendedor.
      CREDITOS = {
        "original_cost_of_goods_sold" => { tipo: :sale, rotulo: "Venda" },
        "seller_return_refund" => { tipo: :adjustment, rotulo: "Devolução parcial" },
        "shopee_discount" => { tipo: :adjustment, rotulo: "Rebate Shopee" },
        "buyer_paid_shipping_fee" => { tipo: :adjustment, rotulo: "Frete pago pelo comprador" },
        "shopee_shipping_rebate" => { tipo: :adjustment, rotulo: "Subsídio de frete Shopee" },
        "shipping_fee_discount_from_3pl" => { tipo: :adjustment, rotulo: "Desconto de frete 3PL" },
        "rsf_seller_protection_fee_claim_amount" => { tipo: :adjustment, rotulo: "Sinistro de proteção" },
        "buyer_paid_packaging_fee" => { tipo: :adjustment, rotulo: "Embalagem paga pelo comprador" }
      }.freeze

      # Saem do que o vendedor recebe.
      DEBITOS = {
        "original_shopee_discount" => { tipo: :adjustment, rotulo: "Rebate Shopee (estorno)" },
        "voucher_from_seller" => { tipo: :adjustment, rotulo: "Cupom do vendedor" },
        "seller_coin_cash_back" => { tipo: :adjustment, rotulo: "Moedas do vendedor" },
        "actual_shipping_fee" => { tipo: :fee, rotulo: "Frete" },
        "reverse_shipping_fee" => { tipo: :fee, rotulo: "Frete reverso" },
        "final_return_to_seller_shipping_fee" => { tipo: :fee, rotulo: "Frete de devolução ao vendedor" },
        "seller_transaction_fee" => { tipo: :fee, rotulo: "Taxa de transação" },
        "service_fee" => { tipo: :fee, rotulo: "Taxa de serviço" },
        "commission_fee" => { tipo: :fee, rotulo: "Comissão" },
        "campaign_fee" => { tipo: :fee, rotulo: "Taxa de campanha" },
        "shipping_seller_protection_fee_amount" => { tipo: :fee, rotulo: "Proteção de envio" },
        "delivery_seller_protection_fee_premium_amount" => { tipo: :fee, rotulo: "Seguro de entrega" },
        "final_escrow_product_gst" => { tipo: :fee, rotulo: "GST sobre produto" },
        "order_ams_commission_fee" => { tipo: :fee, rotulo: "Comissão de afiliado" },
        "escrow_tax" => { tipo: :fee, rotulo: "Imposto" },
        "sales_tax_on_lvg" => { tipo: :fee, rotulo: "Imposto LVG" },
        "reverse_shipping_fee_sst" => { tipo: :fee, rotulo: "SST frete reverso" },
        "shipping_fee_sst" => { tipo: :fee, rotulo: "SST frete" },
        "withholding_tax" => { tipo: :fee, rotulo: "Imposto retido" },
        "overseas_return_service_fee" => { tipo: :fee, rotulo: "Devolução internacional" },
        "vat_on_imported_goods" => { tipo: :fee, rotulo: "VAT importação" },
        "withholding_vat_tax" => { tipo: :fee, rotulo: "VAT retido" },
        "withholding_pit_tax" => { tipo: :fee, rotulo: "IR pessoa física retido" },
        "withholding_cit_tax" => { tipo: :fee, rotulo: "IR pessoa jurídica retido" },
        "seller_order_processing_fee" => { tipo: :fee, rotulo: "Processamento do pedido" },
        "trade_in_bonus_by_seller" => { tipo: :adjustment, rotulo: "Bônus de troca" },
        "fbs_fee" => { tipo: :fee, rotulo: "Fulfillment Shopee" },
        "ads_escrow_top_up_fee_or_technical_support_fee" => { tipo: :fee, rotulo: "Anúncios / suporte técnico" },
        "th_import_duty" => { tipo: :fee, rotulo: "Imposto de importação" }
      }.freeze

      attr_reader :diferenca

      # `liberado_em` vem da LISTA (escrow_release_time): o detalhe não traz
      # data, e sem ela o lançamento não cai no período certo.
      def initialize(resposta, liberado_em: nil)
        # Aceita tanto o envelope inteiro quanto o conteúdo de `response`.
        @detalhe = resposta["response"] || resposta

        @renda = @detalhe["order_income"] || {}

        @liberado_em = liberado_em

        @diferenca = nil
      end

      def call
        return [] if pedido.blank?

        eventos = creditos + debitos + ajustes

        @diferenca = conferir(eventos)

        eventos
      end

      # A nossa decomposição fecha com o líquido que a Shopee informou?
      def confere? = diferenca.present? && diferenca.abs <= TOLERANCIA

      private

      attr_reader :detalhe,
                  :renda,
                  :liberado_em

      def pedido = detalhe["order_sn"].to_s.presence

      def creditos
        CREDITOS.filter_map { |campo, regra| evento(campo, regra, :credit) }
      end

      def debitos
        DEBITOS.filter_map { |campo, regra| evento(campo, regra, :debit) }
      end

      # Ajustes de pedido vêm em lista, com data e motivo próprios.
      def ajustes
        Array(renda["order_adjustment"]).each_with_index.filter_map do |ajuste, i|
          valor = decimal(ajuste["amount"])

          next if valor.zero?

          base(
            sufixo: "ADJ-#{i}",
            tipo: :adjustment,
            direcao: valor.negative? ? :debit : :credit,
            valor: valor.abs,
            rotulo: ajuste["adjustment_reason"].presence || "Ajuste do pedido",
            ocorrido: hora(ajuste["date"])
          )
        end
      end

      def evento(campo, regra, direcao)
        valor = decimal(renda[campo])

        return if valor.zero?

        # Valor negativo onde se espera positivo inverte a direção: é assim que
        # a Shopee representa estorno de uma dedução.
        invertido = valor.negative?

        base(
          sufixo: campo.upcase,
          tipo: regra[:tipo],
          direcao: invertido ? oposto(direcao) : direcao,
          valor: valor.abs,
          rotulo: regra[:rotulo]
        )
      end

      def base(sufixo:, tipo:, direcao:, valor:, rotulo:, ocorrido: nil)
        {
          external_id: "SHOPEE-#{pedido}-#{sufixo}",
          platform: PLATFORM,
          entry_type: tipo,
          direction: direcao,
          amount: valor,
          currency: moeda,
          occurred_at: ocorrido || liberado_em,
          available_on: (ocorrido || liberado_em)&.to_date,
          external_order_id: pedido,
          description: rotulo,
          metadata: { "campo" => sufixo.downcase, "order_sn" => pedido }.compact
        }
      end

      def oposto(direcao) = direcao == :credit ? :debit : :credit

      # A soma dos créditos menos a dos débitos tem que dar o escrow_amount.
      # Quando há ajuste de pedido, o alvo é o valor após ajuste.
      def conferir(eventos)
        credito = eventos.select { |e| e[:direction] == :credit }.sum { |e| e[:amount] }

        debito = eventos.select { |e| e[:direction] == :debit }.sum { |e| e[:amount] }

        (credito - debito - liquido_informado).round(2)
      end

      def liquido_informado
        informado = renda["escrow_amount_after_adjustment"]

        informado = renda["escrow_amount"] if informado.nil?

        decimal(informado)
      end

      def moeda
        renda["aff_currency"].presence || "BRL"
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
