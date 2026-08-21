class CreateConvites < ActiveRecord::Migration[8.1]
  def change
    # Convite por link: o admin gera, copia e envia por onde quiser. A senha é
    # definida por quem recebe, então nunca passa pelas mãos de quem convidou.
    create_table :convites do |t|
      t.references :tenant, null: false, foreign_key: true

      # Quem gerou. Fica para auditoria: chave de acesso é evento a rastrear.
      t.references :convidado_por, null: true, foreign_key: { to_table: :users }

      t.string :email, null: false

      t.string :role, null: false, default: "member"

      # Só o SHA-256 do token, como nas sessões: quem tiver o banco não
      # consegue reconstruir um link válido.
      t.string :token_digest, null: false

      t.datetime :expires_at, null: false

      t.datetime :accepted_at

      t.datetime :revoked_at

      t.timestamps
    end

    add_index :convites, :token_digest, unique: true
    add_index :convites, %i[tenant_id email]
  end
end
