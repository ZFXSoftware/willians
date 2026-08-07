class CreateSessions < ActiveRecord::Migration[8.1]
  def change
    create_table :sessions do |t|
      t.references :user, null: false, foreign_key: true

      # Só o hash do token é persistido. Vazar um dump do banco não dá acesso a
      # nenhuma sessão ativa.
      t.string :token_digest, null: false

      t.datetime :expires_at, null: false
      t.datetime :last_used_at
      t.datetime :revoked_at

      t.string :ip_address
      t.string :user_agent

      t.timestamps
    end

    add_index :sessions, :token_digest, unique: true
    add_index :sessions, :expires_at
  end
end
