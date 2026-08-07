class AddAuthenticationToUsers < ActiveRecord::Migration[8.1]
  def change
    add_column :users, :password_digest, :string
    add_column :users, :status, :string, null: false, default: "active"
    add_column :users, :last_login_at, :datetime

    change_column_null :users, :name, false
    change_column_null :users, :email, false

    # Emails são comparados sempre em minúsculas (o model normaliza na escrita).
    add_index :users, :email, unique: true
    add_index :users, :status
  end
end
