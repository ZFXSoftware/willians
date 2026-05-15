class CreateTenants < ActiveRecord::Migration[8.0]
  def change
    create_table :tenants do |t|
      t.string :name,
               null: false

      t.string :document

      t.string :status,
               null: false,
               default: "active"

      t.jsonb :metadata,
              null: false,
              default: {}

      t.timestamps
    end

    add_index :tenants, :document
    add_index :tenants, :status
  end
end
