module Financeiro
  class ReceivableEngine
    def initialize(financial_entry:)
      @financial_entry = financial_entry
    end

    def call
      return unless sale_entry?

      ActiveRecord::Base.transaction do
        receivable =
          create_receivable!

        allocate_entries!(receivable)

        receivable
      end
    end

    private

    attr_reader :financial_entry

    def sale_entry?
      financial_entry.sale?
    end

    def create_receivable!
      gross_amount =
        financial_entry.amount

      fee_amount =
        marketplace_fee_total

      net_amount =
        gross_amount - fee_amount

      ReceivableUnit.create!(
        tenant: financial_entry.tenant,

        platform_account:
          financial_entry.platform_account,

        order:
          financial_entry.order,

        invoice:
          financial_entry.invoice,

        external_id:
          financial_entry.external_id,

        status: :scheduled,

        gross_amount: gross_amount,

        fee_amount: fee_amount,

        net_amount: net_amount,

        expected_on:
          expected_release_date,

        metadata: {
          source_entry_id:
            financial_entry.id
        }
      )
    end

    def allocate_entries!(receivable)
      related_entries.each do |entry|
        FinancialEntryAllocation.create!(
          financial_entry: entry,

          receivable_unit: receivable
        )
      end
    end

    def related_entries
      FinancialEntry.where(
        tenant: financial_entry.tenant,
        order_id: financial_entry.order_id
      )
    end

    def marketplace_fee_total
      related_entries
        .fees
        .sum(:amount)
    end

    def expected_release_date
      financial_entry.available_on ||
        14.days.from_now.to_date
    end
  end
end