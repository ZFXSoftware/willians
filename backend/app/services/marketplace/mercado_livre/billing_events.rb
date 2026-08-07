module Marketplace
  module MercadoLivre
    # Converte o resumo de faturamento do Mercado Livre em lançamentos do ledger.
    #
    # Encargos (`charges`) viram débitos do tipo `fee`; bonificações (`bonuses`),
    # que são devoluções desses encargos, viram créditos do tipo `adjustment`.
    #
    # Só períodos FECHADOS são ingeridos. Enquanto o período está OPEN os valores
    # ainda mudam, e o ledger é imutável — ingerir cedo congelaria um valor
    # parcial para sempre, porque a deduplicação por external_id ignoraria as
    # atualizações seguintes.
    class BillingEvents
      SOURCE = :mercado_livre

      DEFAULT_GROUPS = %w[ML MP].freeze

      CLOSED = "CLOSED".freeze

      def initialize(client:, groups: DEFAULT_GROUPS)
        @client = client

        @groups = groups
      end

      def call(start_date:, end_date:)
        groups.flat_map do |group|
          closed_periods_in(group, start_date, end_date).flat_map do |period|
            events_for(group, period)
          end
        end
      end

      private

      attr_reader :client,
                  :groups

      def closed_periods_in(group, start_date, end_date)
        client
          .periods(group: group)
          .select { |period| closed?(period) && overlaps?(period, start_date, end_date) }
      end

      def closed?(period)
        period["period_status"].to_s.upcase == CLOSED
      end

      def overlaps?(period, start_date, end_date)
        range = period["period"] || {}

        from = parse_date(range["date_from"])

        to = parse_date(range["date_to"])

        return false if from.blank? || to.blank?

        from <= end_date.to_date && to >= start_date.to_date
      end

      def events_for(group, period)
        key = BillingClient.period_key_for(period)

        return [] if key.blank?

        summary = client.summary(key: key, group: group)

        includes = summary["bill_includes"] || {}

        charge_events(group, key, period, includes["charges"]) +
          bonus_events(group, key, period, includes["bonuses"])
      end

      def charge_events(group, key, period, charges)
        aggregate(charges).map do |identity, data|
          build_event(group, key, period, identity, data, entry_type: :fee, direction: :debit)
        end
      end

      def bonus_events(group, key, period, bonuses)
        aggregate(bonuses).map do |identity, data|
          build_event(group, key, period, identity, data, entry_type: :adjustment, direction: :credit)
        end
      end

      # Agrupa por (type, groupId) e soma. O `label` é texto de exibição e pode
      # mudar; a identidade estável do encargo é o par tipo + grupo.
      def aggregate(items)
        Array(items).each_with_object({}) do |item, acc|
          identity = [item["type"].to_s, item["groupId"]].join("-")

          entry = acc[identity] ||= { amount: BigDecimal("0"), labels: [], raw: [] }

          entry[:amount] += item["amount"].to_d

          entry[:labels] << item["label"]

          entry[:raw] << item
        end
      end

      def build_event(group, key, period, identity, data, entry_type:, direction:)
        {
          external_id: "MLBILL-#{group}-#{key}-#{entry_type}-#{identity}",

          external_order_id: nil,

          source: SOURCE,

          entry_type: entry_type,

          direction: direction,

          amount: data[:amount].abs,

          occurred_at: occurred_at_for(period),

          available_on: nil,

          raw_payload: {
            "origem" => "billing_summary",
            "group" => group,
            "period_key" => key,
            "period" => period["period"],
            "labels" => data[:labels].compact.uniq,
            "itens" => data[:raw]
          }
        }
      end

      # O encargo é do período inteiro; ancorar no fim dele é o que mais se
      # aproxima da competência.
      def occurred_at_for(period)
        to = parse_date((period["period"] || {})["date_to"])

        (to || Date.current).to_time(:utc).end_of_day
      end

      def parse_date(value)
        return if value.blank?

        Date.parse(value.to_s)
      rescue Date::Error
        nil
      end
    end
  end
end
