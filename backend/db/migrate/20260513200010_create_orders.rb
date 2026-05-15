class CreateOrders < ActiveRecord::Migration[8.0]
  def change
    create_table :orders do |t|
      t.references :tenant,
                   null: false,
                   foreign_key: true

      t.references :platform_account,
                   foreign_key: true

      t.string :external_id,
               null: false

      t.string :external_reference

      t.string :platform,
               null: false

      t.string :status,
               null: false,
               default: "pending"

      t.string :buyer_name
      t.string :buyer_document

      t.decimal :total_amount,
                precision: 15,
                scale: 2,
                null: false,
                default: 0

      t.decimal :shipping_amount,
                precision: 15,
                scale: 2,
                null: false,
                default: 0

      t.decimal :discount_amount,
                precision: 15,
                scale: 2,
                null: false,
                default: 0

      t.decimal :paid_amount,
                precision: 15,
                scale: 2,
                null: false,
                default: 0

      t.string :currency,
               null: false,
               default: "BRL"

      t.datetime :ordered_at
      t.datetime :approved_at
      t.datetime :delivered_at
      t.datetime :cancelled_at

      t.jsonb :metadata,
              null: false,
              default: {}

      t.timestamps
    end

    add_index :orders,
              [:tenant_id, :platform, :external_id],
              unique: true,
              name: "idx_orders_unique"

    add_index :orders, :status
    add_index :orders, :ordered_at
    add_index :orders, :approved_at
  end
end