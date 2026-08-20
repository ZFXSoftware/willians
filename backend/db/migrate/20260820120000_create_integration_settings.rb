class CreateIntegrationSettings < ActiveRecord::Migration[8.1]
  def change
    create_table :integration_settings do |t|
      t.references :tenant, null: false, foreign_key: true

      t.string :provider, null: false

      t.string :key, null: false

      # Cifrado em repouso pelo Active Record Encryption. Guarda também os
      # valores não secretos (região, flags) — uma coluna só simplifica, e
      # cifrar o que não precisa não custa nada.
      t.text :value

      # Quem gravou por último. Chave de API trocada é evento de auditoria.
      t.references :updated_by, null: true, foreign_key: { to_table: :users }

      t.timestamps
    end

    add_index :integration_settings, %i[tenant_id provider key], unique: true
  end
end
