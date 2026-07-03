class CreatePlatformBalanceSnapshots < ActiveRecord::Migration[8.1]
  def change
    create_table :platform_balance_snapshots do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :platform_account, null: false, foreign_key: true
      t.date :snapshot_date
      t.decimal :available_balance, precision: 15, scale: 2
      t.decimal :future_balance, precision: 15, scale: 2
      t.decimal :blocked_balance, precision: 15, scale: 2
      t.jsonb :metadata

      t.timestamps
    end
  end
end
