class CreateDevolucoes < ActiveRecord::Migration[8.1]
  def change
    # Briefing 2.8: a devolução precisa ser rastreável da abertura da disputa
    # até o ajuste financeiro. Os lançamentos de estorno já existiam soltos no
    # razão; faltava o registro que os costura ao pedido, à NF de venda e à NF
    # de devolução, com um estado que avança.
    create_table :devolucoes do |t|
      t.references :tenant, null: false, foreign_key: true
      t.references :platform_account, null: true, foreign_key: true

      # A origem: de onde a devolução veio.
      t.references :order, null: true, foreign_key: true
      t.references :invoice, null: true, foreign_key: true

      # A NF de devolução propriamente dita (nota de entrada).
      t.bigint :return_invoice_id, null: true

      # Identificador no marketplace (id do pagamento estornado, da disputa).
      t.string :external_id, null: false

      t.string :platform
      t.string :kind, null: false, default: "devolucao"
      t.string :status, null: false, default: "aberta"

      t.decimal :amount, precision: 15, scale: 2, default: "0.0"

      t.datetime :opened_at
      t.datetime :resolved_at

      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :devolucoes, %i[tenant_id external_id], unique: true
    add_index :devolucoes, :status
    add_index :devolucoes, :return_invoice_id
    add_foreign_key :devolucoes, :invoices, column: :return_invoice_id
  end
end
