class CreateReceivableUnits < ActiveRecord::Migration[8.0]
  def change
    create_table :receivable_units do |t|
      t.references :tenant,
                   null: false,
                   foreign_key: true

      t.references :platform_account,
                   foreign_key: true

      t.references :order,
                   foreign_key: true

      t.references :invoice,
                   foreign_key: true

      t.string :external_id

      t.string :status,
               null: false,
               default: "pending"

      t.decimal :gross_amount,
                precision: 15,
                scale: 2,
                default: 0

      t.decimal :fee_amount,
                precision: 15,
                scale: 2,
                default: 0

      t.decimal :net_amount,
                precision: 15,
                scale: 2,
                default: 0

      t.string :currency,
               default: "BRL"

      t.date :expected_on

      t.date :released_on

      t.jsonb :metadata,
              default: {}

      t.timestamps
    end

    add_index :receivable_units,
              [:tenant_id, :external_id],
              unique: true

    add_index :receivable_units,
              :status

    add_index :receivable_units,
              :expected_on
  end
end