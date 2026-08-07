class CreateMarketplaceCredentials < ActiveRecord::Migration[8.1]
  def change
    create_table :marketplace_credentials do |t|
      t.references :tenant, null: false, foreign_key: true

      t.references :platform_account,
                   null: false,
                   foreign_key: true,
                   index: { unique: true }

      t.string :platform, null: false

      # Cifrados pela aplicação (Active Record Encryption). `text` porque o
      # ciphertext é bem maior que o valor original.
      t.text :access_token
      t.text :refresh_token

      t.datetime :expires_at

      t.string :external_user_id
      t.string :scope

      t.string :status, null: false, default: "connected"

      t.datetime :last_refreshed_at
      t.datetime :refresh_failed_at
      t.text :refresh_error

      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :marketplace_credentials, :status
    add_index :marketplace_credentials, :expires_at
  end
end
