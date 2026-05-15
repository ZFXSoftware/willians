# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_05_13_203324) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "conciliacao_registros", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.text "descricao"
    t.decimal "diferenca", precision: 15, scale: 2
    t.text "observacao"
    t.string "referencia"
    t.string "status"
    t.datetime "updated_at", null: false
    t.decimal "valor", precision: 15, scale: 2
  end

  create_table "conciliation_runs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "divergent_entries", default: 0, null: false
    t.datetime "finished_at"
    t.jsonb "metadata", default: {}, null: false
    t.string "platform", null: false
    t.integer "reconciled_entries", default: 0, null: false
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.bigint "tenant_id", null: false
    t.integer "total_entries", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["platform"], name: "index_conciliation_runs_on_platform"
    t.index ["status"], name: "index_conciliation_runs_on_status"
    t.index ["tenant_id"], name: "index_conciliation_runs_on_tenant_id"
  end

  create_table "divergence_reports", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.decimal "difference_amount", precision: 15, scale: 2
    t.string "divergence_type", null: false
    t.decimal "expected_amount", precision: 15, scale: 2
    t.bigint "financial_entry_id", null: false
    t.jsonb "metadata", default: {}, null: false
    t.decimal "received_amount", precision: 15, scale: 2
    t.text "resolution_notes"
    t.datetime "resolved_at"
    t.string "status", default: "open", null: false
    t.bigint "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["divergence_type"], name: "index_divergence_reports_on_divergence_type"
    t.index ["financial_entry_id"], name: "index_divergence_reports_on_financial_entry_id"
    t.index ["status"], name: "index_divergence_reports_on_status"
    t.index ["tenant_id"], name: "index_divergence_reports_on_tenant_id"
  end

  create_table "financial_entries", force: :cascade do |t|
    t.decimal "amount", precision: 15, scale: 2, null: false
    t.bigint "conciliacao_registro_id"
    t.datetime "created_at", null: false
    t.text "divergence_reason"
    t.string "entry_type", null: false
    t.datetime "expected_settlement_at"
    t.string "external_id", null: false
    t.string "external_reference"
    t.decimal "fee_amount", precision: 15, scale: 2, default: "0.0", null: false
    t.boolean "has_divergence", default: false, null: false
    t.bigint "invoice_id"
    t.jsonb "metadata", default: {}, null: false
    t.decimal "net_amount", precision: 15, scale: 2, default: "0.0", null: false
    t.datetime "occurred_at", null: false
    t.bigint "order_id"
    t.bigint "platform_account_id"
    t.boolean "reconciled", default: false, null: false
    t.datetime "reconciled_at"
    t.datetime "settled_at"
    t.string "status", default: "pending", null: false
    t.bigint "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.decimal "virtual_balance_after", precision: 15, scale: 2
    t.index ["conciliacao_registro_id"], name: "index_financial_entries_on_conciliacao_registro_id"
    t.index ["entry_type"], name: "index_financial_entries_on_entry_type"
    t.index ["expected_settlement_at"], name: "index_financial_entries_on_expected_settlement_at"
    t.index ["has_divergence"], name: "index_financial_entries_on_has_divergence"
    t.index ["invoice_id"], name: "index_financial_entries_on_invoice_id"
    t.index ["occurred_at"], name: "index_financial_entries_on_occurred_at"
    t.index ["order_id"], name: "index_financial_entries_on_order_id"
    t.index ["platform_account_id"], name: "index_financial_entries_on_platform_account_id"
    t.index ["reconciled"], name: "index_financial_entries_on_reconciled"
    t.index ["status"], name: "index_financial_entries_on_status"
    t.index ["tenant_id", "external_id", "entry_type"], name: "idx_financial_entries_unique", unique: true
    t.index ["tenant_id"], name: "index_financial_entries_on_tenant_id"
  end

  create_table "financial_entry_allocations", force: :cascade do |t|
    t.decimal "allocated_amount", precision: 15, scale: 2, null: false
    t.string "allocation_type", null: false
    t.datetime "created_at", null: false
    t.bigint "financial_entry_id", null: false
    t.bigint "invoice_id"
    t.jsonb "metadata", default: {}, null: false
    t.bigint "order_id"
    t.bigint "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["allocated_amount"], name: "index_financial_entry_allocations_on_allocated_amount"
    t.index ["allocation_type"], name: "index_financial_entry_allocations_on_allocation_type"
    t.index ["financial_entry_id"], name: "index_financial_entry_allocations_on_financial_entry_id"
    t.index ["invoice_id"], name: "index_financial_entry_allocations_on_invoice_id"
    t.index ["order_id"], name: "index_financial_entry_allocations_on_order_id"
    t.index ["tenant_id"], name: "index_financial_entry_allocations_on_tenant_id"
  end

  create_table "invoices", force: :cascade do |t|
    t.string "access_key"
    t.datetime "cancelled_at"
    t.datetime "created_at", null: false
    t.string "external_id"
    t.datetime "issued_at"
    t.jsonb "metadata"
    t.string "number"
    t.string "operation_type"
    t.bigint "order_id", null: false
    t.string "series"
    t.string "status"
    t.bigint "tenant_id", null: false
    t.decimal "total_amount"
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_invoices_on_order_id"
    t.index ["tenant_id"], name: "index_invoices_on_tenant_id"
  end

  create_table "nota_fiscals", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "numero"
    t.datetime "updated_at", null: false
    t.decimal "valor"
  end

  create_table "omie_financial_mappings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "financial_entry_id", null: false
    t.jsonb "metadata", default: {}, null: false
    t.string "omie_account_id"
    t.string "omie_category_id"
    t.string "omie_financial_id"
    t.boolean "synced", default: false, null: false
    t.datetime "synced_at"
    t.bigint "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["financial_entry_id"], name: "index_omie_financial_mappings_on_financial_entry_id"
    t.index ["omie_financial_id"], name: "index_omie_financial_mappings_on_omie_financial_id"
    t.index ["synced"], name: "index_omie_financial_mappings_on_synced"
    t.index ["tenant_id"], name: "index_omie_financial_mappings_on_tenant_id"
  end

  create_table "orders", force: :cascade do |t|
    t.datetime "approved_at"
    t.string "buyer_document"
    t.string "buyer_name"
    t.datetime "cancelled_at"
    t.datetime "created_at", null: false
    t.string "currency", default: "BRL", null: false
    t.datetime "delivered_at"
    t.decimal "discount_amount", precision: 15, scale: 2, default: "0.0", null: false
    t.string "external_id", null: false
    t.string "external_reference"
    t.jsonb "metadata", default: {}, null: false
    t.datetime "ordered_at"
    t.decimal "paid_amount", precision: 15, scale: 2, default: "0.0", null: false
    t.string "platform", null: false
    t.bigint "platform_account_id"
    t.decimal "shipping_amount", precision: 15, scale: 2, default: "0.0", null: false
    t.string "status", default: "pending", null: false
    t.bigint "tenant_id", null: false
    t.decimal "total_amount", precision: 15, scale: 2, default: "0.0", null: false
    t.datetime "updated_at", null: false
    t.index ["approved_at"], name: "index_orders_on_approved_at"
    t.index ["ordered_at"], name: "index_orders_on_ordered_at"
    t.index ["platform_account_id"], name: "index_orders_on_platform_account_id"
    t.index ["status"], name: "index_orders_on_status"
    t.index ["tenant_id", "platform", "external_id"], name: "idx_orders_unique", unique: true
    t.index ["tenant_id"], name: "index_orders_on_tenant_id"
  end

  create_table "platform_accounts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "external_id"
    t.jsonb "metadata", default: {}, null: false
    t.string "name", null: false
    t.string "platform", null: false
    t.string "status", default: "active", null: false
    t.bigint "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["platform"], name: "index_platform_accounts_on_platform"
    t.index ["status"], name: "index_platform_accounts_on_status"
    t.index ["tenant_id", "platform", "external_id"], name: "idx_platform_accounts_unique", unique: true
    t.index ["tenant_id"], name: "index_platform_accounts_on_tenant_id"
  end

  create_table "tenant_users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "role"
    t.string "supabase_user_id"
    t.bigint "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["tenant_id"], name: "index_tenant_users_on_tenant_id"
  end

  create_table "tenants", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "document"
    t.jsonb "metadata", default: {}, null: false
    t.string "name", null: false
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["document"], name: "index_tenants_on_document"
    t.index ["status"], name: "index_tenants_on_status"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "email"
    t.string "name"
    t.datetime "updated_at", null: false
  end

  add_foreign_key "conciliation_runs", "tenants"
  add_foreign_key "divergence_reports", "financial_entries"
  add_foreign_key "divergence_reports", "tenants"
  add_foreign_key "financial_entries", "conciliacao_registros"
  add_foreign_key "financial_entries", "invoices"
  add_foreign_key "financial_entries", "orders"
  add_foreign_key "financial_entries", "platform_accounts"
  add_foreign_key "financial_entries", "tenants"
  add_foreign_key "financial_entry_allocations", "financial_entries"
  add_foreign_key "financial_entry_allocations", "invoices"
  add_foreign_key "financial_entry_allocations", "orders"
  add_foreign_key "financial_entry_allocations", "tenants"
  add_foreign_key "invoices", "orders"
  add_foreign_key "invoices", "tenants"
  add_foreign_key "omie_financial_mappings", "financial_entries"
  add_foreign_key "omie_financial_mappings", "tenants"
  add_foreign_key "orders", "platform_accounts"
  add_foreign_key "orders", "tenants"
  add_foreign_key "platform_accounts", "tenants"
  add_foreign_key "tenant_users", "tenants"
end
