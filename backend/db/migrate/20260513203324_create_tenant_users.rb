class CreateTenantUsers < ActiveRecord::Migration[8.1]
  def change
    create_table :tenant_users do |t|
      t.references :tenant, null: false, foreign_key: true
      t.string :supabase_user_id
      t.string :role

      t.timestamps
    end
  end
end
