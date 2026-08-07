class LinkTenantUsersToUsers < ActiveRecord::Migration[8.1]
  def up
    add_reference :tenant_users, :user, foreign_key: true

    # A tabela nasceu apontando para o Supabase. A identidade agora é local.
    remove_column :tenant_users, :supabase_user_id, :string

    change_column_null :tenant_users, :user_id, false
    change_column_default :tenant_users, :role, from: nil, to: "member"
    change_column_null :tenant_users, :role, false, "member"

    add_index :tenant_users, [:tenant_id, :user_id], unique: true
    add_index :tenant_users, :role
  end

  def down
    remove_index :tenant_users, :role
    remove_index :tenant_users, [:tenant_id, :user_id]

    change_column_null :tenant_users, :role, true
    change_column_default :tenant_users, :role, from: "member", to: nil

    remove_reference :tenant_users, :user, foreign_key: true

    add_column :tenant_users, :supabase_user_id, :string
  end
end
