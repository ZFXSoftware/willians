module Marketplace
  module Ingestors
    # Traz os eventos financeiros de uma conta de marketplace para o ledger.
    #
    # A deduplicação é feita em lote (uma consulta pelos external_ids da janela)
    # em vez de tentar o INSERT e capturar a violação de unicidade evento a
    # evento — além de mais barato, evita abortar a transação no Postgres.
    class MarketplaceIngestor
      PROVIDERS = {
        "mercado_livre" => "Marketplace::Providers::MercadoLivreProvider"
      }.freeze

      FALLBACK_PROVIDER = "Marketplace::Providers::FakeProvider".freeze

      SIMULATION_ENABLED_VALUES = %w[true 1].freeze

      class UnsupportedPlatform < StandardError; end

      class MissingCredentials < StandardError; end

      def initialize(
        tenant:,
        platform_account:,
        start_date:,
        end_date:
      )
        @tenant = tenant

        @platform_account = platform_account

        @start_date = start_date.to_date

        @end_date = end_date.to_date

        @summary = Hash.new(0)
      end

      def call
        events = provider.financial_events(
          start_date: start_date,
          end_date: end_date
        )

        events = events.select { |event| event[:external_id].present? }

        summary[:received] = events.size

        persist!(events, resolve_orders!(events)) if events.any?

        summary
      end

      private

      attr_reader :tenant,
                  :platform_account,
                  :start_date,
                  :end_date,
                  :summary

      def provider
        provider_class.new(account: platform_account)
      end

      # Só cai no provider de simulação quando isso é explicitamente permitido.
      #
      # O comportamento anterior era silencioso: plataforma sem provider ou conta
      # sem credencial gerava lançamentos FICTÍCIOS que entravam no ledger como
      # se fossem reais — e a conciliação depois bateria contra eles.
      def provider_class
        name = PROVIDERS[platform_account.platform.to_s]

        if name.blank?
          raise UnsupportedPlatform, unsupported_message unless simulation_allowed?

          return FALLBACK_PROVIDER.constantize
        end

        klass = name.constantize

        return klass if klass.configured?(platform_account)

        raise MissingCredentials, missing_credentials_message unless simulation_allowed?

        FALLBACK_PROVIDER.constantize
      end

      def simulation_allowed?
        flag = ENV["MARKETPLACE_SIMULATION"].to_s.strip.downcase

        return SIMULATION_ENABLED_VALUES.include?(flag) if flag.present?

        Rails.env.local?
      end

      def unsupported_message
        "Não há integração implementada para a plataforma '#{platform_account.platform}' " \
          "(conta ##{platform_account.id}). Plataformas suportadas: #{PROVIDERS.keys.join(', ')}."
      end

      def missing_credentials_message
        "Conta ##{platform_account.id} (#{platform_account.platform}) não está conectada. " \
          "Autorize o acesso pelo fluxo de OAuth antes de ingerir."
      end

      def resolve_orders!(events)
        refs = events.filter_map { |event| event[:external_order_id] }.uniq

        return {} if refs.empty?

        create_missing_orders!(refs)

        orders_scope(refs).pluck(:external_id, :id).to_h
      end

      def create_missing_orders!(refs)
        known = orders_scope(refs).pluck(:external_id).to_set

        missing = refs.reject { |ref| known.include?(ref) }

        return if missing.empty?

        now = Time.current

        Order.insert_all(
          missing.map { |ref| order_row(ref, now) },
          unique_by: :idx_orders_unique
        )
      end

      def order_row(ref, now)
        {
          tenant_id: tenant.id,

          platform_account_id: platform_account.id,

          platform: platform_account.platform,

          external_id: ref,

          status: "pending",

          currency: "BRL",

          metadata: { origem: "marketplace_ingestor" },

          created_at: now,

          updated_at: now
        }
      end

      def orders_scope(refs)
        Order.where(
          tenant_id: tenant.id,
          platform: platform_account.platform,
          external_id: refs
        )
      end

      def persist!(events, orders)
        known = known_external_ids(events)

        events.each do |event|
          next summary[:skipped] += 1 if known.include?(event[:external_id])

          create_entry!(event, orders)
        end
      end

      def known_external_ids(events)
        FinancialEntry
          .where(
            tenant_id: tenant.id,
            external_id: events.map { |event| event[:external_id] }
          )
          .pluck(:external_id)
          .to_set
      end

      def create_entry!(event, orders)
        FinancialEntry.create!(
          tenant: tenant,

          platform_account: platform_account,

          order_id: orders[event[:external_order_id]],

          external_id: event[:external_id],

          external_reference: event[:external_order_id],

          source: event[:source],

          entry_type: event[:entry_type],

          direction: event[:direction],

          amount: event[:amount],

          occurred_at: event[:occurred_at],

          available_on: event[:available_on],

          raw_payload: event[:raw_payload],

          status: :pending
        )

        summary[:created] += 1
      rescue ActiveRecord::RecordNotUnique
        summary[:skipped] += 1
      rescue ActiveRecord::RecordInvalid => e
        Rails.logger.warn "[MarketplaceIngestor] Evento #{event[:external_id]} inválido: #{e.message}"

        summary[:failed] += 1
      end
    end
  end
end
