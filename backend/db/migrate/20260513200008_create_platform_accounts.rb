class CreatePlatformAccounts < ActiveRecord::Migration[8.0]
  def change
    create_table :platform_accounts do |t|
      t.references :tenant, null: false, foreign_key: true

      t.string :name, null: false
      t.string :platform, null: false

      t.string :external_id

      t.string :status,
               null: false,
               default: "active"

      t.jsonb :metadata,
              null: false,
              default: {}

      t.timestamps
    end

    add_index :platform_accounts,
              [:tenant_id, :platform, :external_id],
              unique: true,
              name: "idx_platform_accounts_unique"

    add_index :platform_accounts, :platform
    add_index :platform_accounts, :status
  end
end