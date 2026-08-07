module Marketplace
  module Providers
    # Provider de SIMULAÇÃO para contas sem credencial configurada.
    #
    # Gera eventos determinísticos (mesma janela => mesmos external_ids), o que
    # deixa a ingestão idempotente e permite exercitar venda -> taxa -> recebível
    # sem depender de API externa.
    class FakeProvider < BaseProvider
      ORDERS_PER_DAY = 2

      SALE_AMOUNTS = [
        BigDecimal("129.90"),
        BigDecimal("249.50"),
        BigDecimal("87.30"),
        BigDecimal("540.00")
      ].freeze

      FEE_RATE = BigDecimal("0.16")

      RELEASE_DAYS = 14

      def self.configured?(_account)
        true
      end

      def financial_events(start_date:, end_date:)
        (start_date.to_date..end_date.to_date).flat_map do |date|
          ORDERS_PER_DAY.times.flat_map do |index|
            events_for(date, index)
          end
        end
      end

      private

      def events_for(date, index)
        order_ref = "SIM-#{account.id}-#{date.strftime('%Y%m%d')}-#{index}"

        gross = SALE_AMOUNTS[(date.yday + index) % SALE_AMOUNTS.size]

        fee = (gross * FEE_RATE).round(2)

        [
          event(order_ref, "SALE", gross, date),
          event(order_ref, "FEE", fee, date)
        ]
      end

      def event(order_ref, type, amount, date)
        normalize(
          account.platform.to_sym,

          "id" => "#{order_ref}-#{type}",

          "order_id" => order_ref,

          "type" => type,

          "amount" => amount.to_s,

          "created_at" => date.to_time.iso8601,

          "available_on" => (date + RELEASE_DAYS).iso8601
        )
      end
    end
  end
end
