class CreateOauthStates < ActiveRecord::Migration[8.1]
  def change
    create_table :oauth_states do |t|
      # Liga o retorno do marketplace a quem iniciou a autorização. Sem isso,
      # qualquer um poderia chamar o callback e vincular a própria conta do
      # marketplace ao tenant de outro cliente.
      t.string :state, null: false

      t.string :platform, null: false

      t.references :tenant, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true

      t.references :platform_account, foreign_key: true

      t.string :code_verifier

      t.datetime :expires_at, null: false
      t.datetime :consumed_at

      t.timestamps
    end

    add_index :oauth_states, :state, unique: true
    add_index :oauth_states, :expires_at
  end
end
