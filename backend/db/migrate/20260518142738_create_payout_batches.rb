class CreatePayoutBatches < ActiveRecord::Migration[8.1]
  def change
    create_table :payout_batches do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :platform_account, null: false, foreign_key: true
      t.string :external_id
      t.string :status
      t.decimal :gross_amount, precision: 15, scale: 2
      t.decimal :fee_amount, precision: 15, scale: 2
      t.decimal :net_amount, precision: 15, scale: 2
      t.datetime :paid_at

      t.timestamps
    end
  end
end
