module Financeiro
  # Projeta o recebível de um pedido a partir dos lançamentos do ledger.
  #
  # É disparado no after_commit de cada lançamento novo. Taxas e estornos chegam
  # do marketplace depois da venda, então o engine recalcula o recebível a cada
  # lançamento relacionado em vez de congelar o valor no momento da venda.
  #
  # Recebíveis já pagos ou cancelados não são recalculados: o repasse
  # correspondente já foi liquidado em cima dos valores antigos.
  class ReceivableEngine
    DEFAULT_RELEASE_DAYS = 14

    TRIGGER_TYPES = %w[sale fee refund chargeback].freeze

    FROZEN_STATUSES = %w[paid cancelled].freeze

    DEDUCTION_TYPES = %w[refund chargeback].freeze

    def initialize(financial_entry:)
      @financial_entry = financial_entry
    end

    def call
      return unless trigger?

      anchor = anchor_entry

      return if anchor.blank?

      ActiveRecord::Base.transaction do
        entries = related_entries(anchor)

        receivable = upsert_receivable!(anchor, totals_for(entries))

        allocate!(receivable, entries) unless frozen?(receivable)

        receivable
      end
    end

    private

    attr_reader :financial_entry

    def trigger?
      TRIGGER_TYPES.include?(financial_entry.entry_type)
    end

    # Uma taxa ou estorno só gera recebível se existir a venda que os ancora.
    def anchor_entry
      return financial_entry if financial_entry.sale?

      return if financial_entry.order_id.blank?

      FinancialEntry
        .sales
        .find_by(
          tenant_id: financial_entry.tenant_id,
          order_id: financial_entry.order_id
        )
    end

    # Sem pedido não há como agrupar: o lançamento responde por si só. Agrupar
    # por `order_id: nil` casaria com todos os lançamentos órfãos do tenant.
    def related_entries(anchor)
      return [anchor] if anchor.order_id.blank?

      FinancialEntry
        .where(
          tenant_id: anchor.tenant_id,
          order_id: anchor.order_id
        )
        .to_a
    end

    def totals_for(entries)
      gross =
        sum_of(entries) { |entry| entry.entry_type == "sale" }

      fee =
        sum_of(entries) { |entry| entry.entry_type == "fee" }

      deductions =
        sum_of(entries) { |entry| DEDUCTION_TYPES.include?(entry.entry_type) }

      {
        gross_amount: gross,
        fee_amount: fee,
        deductions: deductions,
        net_amount: gross - fee - deductions
      }
    end

    def sum_of(entries)
      entries.sum(BigDecimal("0")) do |entry|
        yield(entry) ? entry.amount.to_d : BigDecimal("0")
      end
    end

    def upsert_receivable!(anchor, totals)
      receivable = find_receivable(anchor)

      return receivable if receivable && frozen?(receivable)

      if receivable
        receivable.update!(attributes_for(anchor, totals))

        receivable
      else
        create_receivable!(anchor, totals)
      end
    end

    def find_receivable(anchor)
      ReceivableUnit.find_by(
        tenant_id: anchor.tenant_id,
        external_id: anchor.external_id
      )
    end

    def create_receivable!(anchor, totals)
      ReceivableUnit.create!(
        attributes_for(anchor, totals).merge(
          tenant_id: anchor.tenant_id,

          external_id: anchor.external_id,

          status: :scheduled
        )
      )
    rescue ActiveRecord::RecordNotUnique
      # Corrida entre dois lançamentos do mesmo pedido commitando junto.
      receivable = find_receivable(anchor)

      raise if receivable.blank?

      receivable.update!(attributes_for(anchor, totals)) unless frozen?(receivable)

      receivable
    end

    def attributes_for(anchor, totals)
      {
        platform_account_id: anchor.platform_account_id,

        order_id: anchor.order_id,

        invoice_id: anchor.invoice_id,

        gross_amount: totals[:gross_amount],

        fee_amount: totals[:fee_amount],

        net_amount: totals[:net_amount],

        expected_on: expected_release_date(anchor),

        metadata: {
          source_entry_id: anchor.id,
          deductions: totals[:deductions].to_s,
          recalculated_at: Time.current
        }
      }
    end

    def frozen?(receivable)
      receivable.blank? || FROZEN_STATUSES.include?(receivable.status)
    end

    def allocate!(receivable, entries)
      already_allocated =
        FinancialEntryAllocation
          .where(
            receivable_unit_id: receivable.id,
            allocation_type: :receivable
          )
          .pluck(:financial_entry_id)
          .to_set

      now = Time.current

      rows =
        entries.reject { |entry| already_allocated.include?(entry.id) }
               .map { |entry| allocation_row(receivable, entry, now) }

      return if rows.empty?

      FinancialEntryAllocation.insert_all(
        rows,
        unique_by: :idx_allocations_unique
      )
    end

    def allocation_row(receivable, entry, now)
      {
        tenant_id: entry.tenant_id,

        financial_entry_id: entry.id,

        receivable_unit_id: receivable.id,

        order_id: entry.order_id,

        invoice_id: entry.invoice_id,

        allocation_type: "receivable",

        allocated_amount: entry.amount,

        amount: entry.amount,

        metadata: {},

        created_at: now,

        updated_at: now
      }
    end

    def expected_release_date(anchor)
      anchor.available_on ||
        DEFAULT_RELEASE_DAYS.days.from_now.to_date
    end
  end
end
