module Financeiro
  class PayoutEngine
    def initialize(
      tenant:,
      platform_account:,
      payout_reference:,
      paid_at:
    )
      @tenant = tenant

      @platform_account = platform_account

      @payout_reference = payout_reference

      @paid_at = paid_at
    end

    def call
      ActiveRecord::Base.transaction do
        payout =
          create_payout_batch!

        allocate_receivables!(payout)

        payout
      end
    end

    private

    attr_reader :tenant,
                :platform_account,
                :payout_reference,
                :paid_at

    def create_payout_batch!
      existing_payout =
        PayoutBatch.find_by(
          tenant: tenant,
          external_id: payout_reference
        )

      return existing_payout if existing_payout

      settlement_entry =
        FinancialEntry.create!(
          tenant: tenant,

          platform_account: platform_account,

          external_id: payout_reference,

          source: platform_account.provider,

          entry_type: :settlement,

          direction: :credit,

          amount: receivables.sum(&:net_amount),

          occurred_at: paid_at,

          available_on: paid_at.to_date,

          status: :settled
        )

      PayoutBatch.create!(
        tenant: tenant,

        platform_account: platform_account,

        financial_entry: settlement_entry,

        external_id: payout_reference,

        status: :paid,

        gross_amount:
          receivables.sum(&:gross_amount),

        fee_amount:
          receivables.sum(&:fee_amount),

        net_amount:
          receivables.sum(&:net_amount),

        paid_at: paid_at
      )
    end

    def allocate_receivables!(payout)
      receivables.each do |receivable|
        allocate_receivable!(
          payout,
          receivable
        )

        receivable.update!(
          status: :paid,
          released_on: paid_at.to_date
        )
      end
    end

    def allocate_receivable!(
      payout,
      receivable
    )
      receivable.financial_entries.each do |entry|
        FinancialEntryAllocation.create!(
          financial_entry: entry,

          receivable_unit: receivable,

          payout_batch: payout,

          allocation_type: :payout,

          amount: entry.amount
        )
      end
    end

    def receivables
      @receivables ||=
        ReceivableUnit.where(
          tenant: tenant,
          platform_account: platform_account,
          status: :scheduled,
          expected_on: ..paid_at.to_date
        )
    end
  end
end