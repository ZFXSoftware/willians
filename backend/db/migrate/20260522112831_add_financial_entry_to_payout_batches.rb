class AddFinancialEntryToPayoutBatches < ActiveRecord::Migration[8.0]
  def change
    add_reference :payout_batches,
                  :financial_entry,
                  foreign_key: true
  end
end