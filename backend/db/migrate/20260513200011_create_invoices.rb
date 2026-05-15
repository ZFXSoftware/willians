class CreateInvoices < ActiveRecord::Migration[8.1]
  def change
    create_table :invoices do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :order, null: false, foreign_key: true
      t.string :external_id
      t.string :number
      t.string :series
      t.string :access_key
      t.string :status
      t.string :operation_type
      t.decimal :total_amount
      t.datetime :issued_at
      t.datetime :cancelled_at
      t.jsonb :metadata

      t.timestamps
    end
  end
end
