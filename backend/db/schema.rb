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

ActiveRecord::Schema[8.1].define(version: 2026_09_04_140000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "certificados_digitais", force: :cascade do |t|
    t.text "arquivo", null: false
    t.string "cnpj"
    t.datetime "created_at", null: false
    t.jsonb "metadata", default: {}, null: false
    t.text "senha", null: false
    t.bigint "tenant_id", null: false
    t.string "titular"
    t.datetime "updated_at", null: false
    t.datetime "valido_ate"
    t.datetime "valido_de"
    t.index ["tenant_id"], name: "idx_certificado_por_empresa", unique: true
    t.index ["tenant_id"], name: "index_certificados_digitais_on_tenant_id"
    t.index ["valido_ate"], name: "index_certificados_digitais_on_valido_ate"
  end

  create_table "conciliacao_registros", force: :cascade do |t|
    t.datetime "conciliated_at"
    t.jsonb "conciliation_metadata", default: {}
    t.bigint "conciliation_run_id"
    t.decimal "confidence_score", precision: 5, scale: 2, default: "0.0"
    t.datetime "created_at", null: false
    t.text "descricao"
    t.decimal "diferenca", precision: 15, scale: 2
    t.bigint "financial_entry_id"
    t.string "match_type"
    t.text "observacao"
    t.bigint "payout_batch_id"
    t.bigint "receivable_unit_id"
    t.string "referencia"
    t.string "status"
    t.bigint "tenant_id"
    t.datetime "updated_at", null: false
    t.decimal "valor", precision: 15, scale: 2
    t.index ["conciliation_run_id"], name: "index_conciliacao_registros_on_conciliation_run_id"
    t.index ["confidence_score"], name: "index_conciliacao_registros_on_confidence_score"
    t.index ["financial_entry_id"], name: "index_conciliacao_registros_on_financial_entry_id"
    t.index ["match_type"], name: "index_conciliacao_registros_on_match_type"
    t.index ["payout_batch_id"], name: "index_conciliacao_registros_on_payout_batch_id"
    t.index ["receivable_unit_id"], name: "index_conciliacao_registros_on_receivable_unit_id"
    t.index ["tenant_id"], name: "index_conciliacao_registros_on_tenant_id"
  end

  create_table "conciliation_runs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "divergences_found", default: 0
    t.integer "divergent_entries", default: 0, null: false
    t.integer "entries_processed", default: 0
    t.datetime "finished_at"
    t.integer "matches_found", default: 0
    t.jsonb "metadata", default: {}, null: false
    t.string "platform", null: false
    t.bigint "platform_account_id"
    t.integer "reconciled_entries", default: 0, null: false
    t.string "source"
    t.datetime "started_at"
    t.string "status", default: "pending", null: false
    t.bigint "tenant_id", null: false
    t.integer "total_entries", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["platform"], name: "index_conciliation_runs_on_platform"
    t.index ["platform_account_id"], name: "index_conciliation_runs_on_platform_account_id"
    t.index ["status"], name: "index_conciliation_runs_on_status"
    t.index ["tenant_id"], name: "index_conciliation_runs_on_tenant_id"
  end

  create_table "convites", force: :cascade do |t|
    t.datetime "accepted_at"
    t.bigint "convidado_por_id"
    t.datetime "created_at", null: false
    t.string "email", null: false
    t.datetime "expires_at", null: false
    t.datetime "revoked_at"
    t.string "role", default: "member", null: false
    t.bigint "tenant_id", null: false
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.index ["convidado_por_id"], name: "index_convites_on_convidado_por_id"
    t.index ["tenant_id", "email"], name: "index_convites_on_tenant_id_and_email"
    t.index ["tenant_id"], name: "index_convites_on_tenant_id"
    t.index ["token_digest"], name: "index_convites_on_token_digest", unique: true
  end

  create_table "devolucoes", force: :cascade do |t|
    t.decimal "amount", precision: 15, scale: 2, default: "0.0"
    t.datetime "created_at", null: false
    t.string "external_id", null: false
    t.bigint "invoice_id"
    t.string "kind", default: "devolucao", null: false
    t.jsonb "metadata", default: {}, null: false
    t.datetime "opened_at"
    t.bigint "order_id"
    t.string "platform"
    t.bigint "platform_account_id"
    t.datetime "resolved_at"
    t.bigint "return_invoice_id"
    t.string "status", default: "aberta", null: false
    t.bigint "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["invoice_id"], name: "index_devolucoes_on_invoice_id"
    t.index ["order_id"], name: "index_devolucoes_on_order_id"
    t.index ["platform_account_id"], name: "index_devolucoes_on_platform_account_id"
    t.index ["return_invoice_id"], name: "index_devolucoes_on_return_invoice_id"
    t.index ["status"], name: "index_devolucoes_on_status"
    t.index ["tenant_id", "external_id"], name: "index_devolucoes_on_tenant_id_and_external_id", unique: true
    t.index ["tenant_id"], name: "index_devolucoes_on_tenant_id"
  end

  create_table "divergence_reports", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.decimal "difference_amount", precision: 15, scale: 2
    t.string "divergence_type", null: false
    t.decimal "expected_amount", precision: 15, scale: 2
    t.bigint "financial_entry_id"
    t.jsonb "metadata", default: {}, null: false
    t.decimal "received_amount", precision: 15, scale: 2
    t.text "resolution_notes"
    t.datetime "resolved_at"
    t.string "status", default: "open", null: false
    t.bigint "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index "tenant_id, divergence_type, ((metadata ->> 'chave'::text))", name: "idx_divergence_reports_sem_lancamento", unique: true, where: "(financial_entry_id IS NULL)"
    t.index ["divergence_type"], name: "index_divergence_reports_on_divergence_type"
    t.index ["financial_entry_id", "divergence_type", "status"], name: "idx_divergence_reports_unique", unique: true
    t.index ["financial_entry_id"], name: "index_divergence_reports_on_financial_entry_id"
    t.index ["status"], name: "index_divergence_reports_on_status"
    t.index ["tenant_id"], name: "index_divergence_reports_on_tenant_id"
  end

  create_table "financial_entries", force: :cascade do |t|
    t.decimal "amount", precision: 15, scale: 2, null: false
    t.date "available_on"
    t.bigint "conciliacao_registro_id"
    t.datetime "created_at", null: false
    t.string "direction"
    t.text "divergence_reason"
    t.string "entry_type", null: false
    t.datetime "expected_settlement_at"
    t.string "external_id", null: false
    t.string "external_reference"
    t.decimal "fee_amount", precision: 15, scale: 2, default: "0.0", null: false
    t.boolean "has_divergence", default: false, null: false
    t.boolean "immutable", default: false, null: false
    t.bigint "invoice_id"
    t.jsonb "metadata", default: {}, null: false
    t.decimal "net_amount", precision: 15, scale: 2, default: "0.0", null: false
    t.datetime "occurred_at", null: false
    t.bigint "order_id"
    t.bigint "platform_account_id"
    t.jsonb "raw_payload", default: {}
    t.boolean "reconciled", default: false, null: false
    t.datetime "reconciled_at"
    t.bigint "reversal_of_id"
    t.datetime "settled_at"
    t.string "source"
    t.string "status", default: "pending", null: false
    t.bigint "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.decimal "virtual_balance_after", precision: 15, scale: 2
    t.index ["available_on"], name: "index_financial_entries_on_available_on"
    t.index ["conciliacao_registro_id"], name: "index_financial_entries_on_conciliacao_registro_id"
    t.index ["direction"], name: "index_financial_entries_on_direction"
    t.index ["entry_type"], name: "index_financial_entries_on_entry_type"
    t.index ["expected_settlement_at"], name: "index_financial_entries_on_expected_settlement_at"
    t.index ["has_divergence"], name: "index_financial_entries_on_has_divergence"
    t.index ["invoice_id"], name: "index_financial_entries_on_invoice_id"
    t.index ["occurred_at"], name: "index_financial_entries_on_occurred_at"
    t.index ["order_id"], name: "index_financial_entries_on_order_id"
    t.index ["platform_account_id"], name: "index_financial_entries_on_platform_account_id"
    t.index ["reconciled"], name: "index_financial_entries_on_reconciled"
    t.index ["reversal_of_id"], name: "index_financial_entries_on_reversal_of_id"
    t.index ["source"], name: "index_financial_entries_on_source"
    t.index ["status"], name: "index_financial_entries_on_status"
    t.index ["tenant_id", "external_id", "entry_type"], name: "idx_financial_entries_unique", unique: true
    t.index ["tenant_id", "source", "external_id"], name: "idx_financial_entries_idempotency", unique: true
    t.index ["tenant_id"], name: "index_financial_entries_on_tenant_id"
  end

  create_table "financial_entry_allocations", force: :cascade do |t|
    t.decimal "allocated_amount", precision: 15, scale: 2, null: false
    t.string "allocation_type", null: false
    t.decimal "amount", precision: 15, scale: 2, default: "0.0"
    t.datetime "created_at", null: false
    t.bigint "financial_entry_id", null: false
    t.bigint "invoice_id"
    t.jsonb "metadata", default: {}, null: false
    t.bigint "order_id"
    t.bigint "payout_batch_id"
    t.bigint "receivable_unit_id"
    t.bigint "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["allocated_amount"], name: "index_financial_entry_allocations_on_allocated_amount"
    t.index ["allocation_type"], name: "index_financial_entry_allocations_on_allocation_type"
    t.index ["financial_entry_id"], name: "index_financial_entry_allocations_on_financial_entry_id"
    t.index ["invoice_id"], name: "index_financial_entry_allocations_on_invoice_id"
    t.index ["order_id"], name: "index_financial_entry_allocations_on_order_id"
    t.index ["payout_batch_id"], name: "index_financial_entry_allocations_on_payout_batch_id"
    t.index ["receivable_unit_id", "financial_entry_id", "allocation_type"], name: "idx_allocations_unique", unique: true
    t.index ["receivable_unit_id"], name: "index_financial_entry_allocations_on_receivable_unit_id"
    t.index ["tenant_id"], name: "index_financial_entry_allocations_on_tenant_id"
  end

  create_table "integration_settings", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "key", null: false
    t.string "provider", null: false
    t.bigint "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "updated_by_id"
    t.text "value"
    t.index ["tenant_id", "provider", "key"], name: "index_integration_settings_on_tenant_id_and_provider_and_key", unique: true
    t.index ["tenant_id"], name: "index_integration_settings_on_tenant_id"
    t.index ["updated_by_id"], name: "index_integration_settings_on_updated_by_id"
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
    t.bigint "order_id"
    t.string "series"
    t.string "status"
    t.bigint "tenant_id", null: false
    t.decimal "total_amount"
    t.datetime "updated_at", null: false
    t.index ["order_id"], name: "index_invoices_on_order_id"
    t.index ["tenant_id"], name: "index_invoices_on_tenant_id"
  end

  create_table "leituras_sefaz", force: :cascade do |t|
    t.datetime "bloqueado_ate"
    t.datetime "consultado_em"
    t.datetime "created_at", null: false
    t.bigint "max_nsu"
    t.jsonb "metadata", default: {}, null: false
    t.bigint "tenant_id", null: false
    t.string "ultimo_motivo"
    t.bigint "ultimo_nsu", default: 0, null: false
    t.string "ultimo_status"
    t.datetime "updated_at", null: false
    t.index ["tenant_id"], name: "idx_leitura_sefaz_por_empresa", unique: true
    t.index ["tenant_id"], name: "index_leituras_sefaz_on_tenant_id"
  end

  create_table "marketplace_credentials", force: :cascade do |t|
    t.text "access_token"
    t.datetime "created_at", null: false
    t.datetime "expires_at"
    t.string "external_user_id"
    t.datetime "last_refreshed_at"
    t.jsonb "metadata", default: {}, null: false
    t.string "platform", null: false
    t.bigint "platform_account_id", null: false
    t.text "refresh_error"
    t.datetime "refresh_failed_at"
    t.text "refresh_token"
    t.string "scope"
    t.string "status", default: "connected", null: false
    t.bigint "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["expires_at"], name: "index_marketplace_credentials_on_expires_at"
    t.index ["platform_account_id"], name: "index_marketplace_credentials_on_platform_account_id", unique: true
    t.index ["status"], name: "index_marketplace_credentials_on_status"
    t.index ["tenant_id"], name: "index_marketplace_credentials_on_tenant_id"
  end

  create_table "nota_fiscals", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "numero"
    t.datetime "updated_at", null: false
    t.decimal "valor"
  end

  create_table "oauth_states", force: :cascade do |t|
    t.string "code_verifier"
    t.datetime "consumed_at"
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "platform", null: false
    t.bigint "platform_account_id"
    t.string "state", null: false
    t.bigint "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["expires_at"], name: "index_oauth_states_on_expires_at"
    t.index ["platform_account_id"], name: "index_oauth_states_on_platform_account_id"
    t.index ["state"], name: "index_oauth_states_on_state", unique: true
    t.index ["tenant_id"], name: "index_oauth_states_on_tenant_id"
    t.index ["user_id"], name: "index_oauth_states_on_user_id"
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

  create_table "payout_batches", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "external_id"
    t.decimal "fee_amount", precision: 15, scale: 2
    t.bigint "financial_entry_id"
    t.decimal "gross_amount", precision: 15, scale: 2
    t.decimal "net_amount", precision: 15, scale: 2
    t.datetime "paid_at"
    t.bigint "platform_account_id", null: false
    t.string "status"
    t.bigint "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["financial_entry_id"], name: "index_payout_batches_on_financial_entry_id"
    t.index ["platform_account_id"], name: "index_payout_batches_on_platform_account_id"
    t.index ["tenant_id", "external_id"], name: "idx_payout_batches_unique", unique: true
    t.index ["tenant_id"], name: "index_payout_batches_on_tenant_id"
  end

  create_table "platform_accounts", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "external_id"
    t.string "last_sync_error"
    t.string "last_sync_status"
    t.datetime "last_synced_at"
    t.jsonb "metadata", default: {}, null: false
    t.string "name", null: false
    t.string "platform", null: false
    t.string "status", default: "active", null: false
    t.bigint "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["last_synced_at"], name: "index_platform_accounts_on_last_synced_at"
    t.index ["platform"], name: "index_platform_accounts_on_platform"
    t.index ["status"], name: "index_platform_accounts_on_status"
    t.index ["tenant_id", "platform", "external_id"], name: "idx_platform_accounts_unique", unique: true
    t.index ["tenant_id"], name: "index_platform_accounts_on_tenant_id"
  end

  create_table "platform_balance_snapshots", force: :cascade do |t|
    t.decimal "available_balance", precision: 15, scale: 2
    t.decimal "blocked_balance", precision: 15, scale: 2
    t.datetime "created_at", null: false
    t.decimal "difference_amount", precision: 15, scale: 2
    t.decimal "future_balance", precision: 15, scale: 2
    t.jsonb "metadata"
    t.bigint "platform_account_id", null: false
    t.decimal "platform_available_balance", precision: 15, scale: 2
    t.decimal "platform_future_balance", precision: 15, scale: 2
    t.string "platform_source"
    t.decimal "platform_total_balance", precision: 15, scale: 2
    t.date "snapshot_date"
    t.bigint "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["platform_account_id", "snapshot_date"], name: "idx_balance_snapshots_conta_data", unique: true
    t.index ["platform_account_id"], name: "index_platform_balance_snapshots_on_platform_account_id"
    t.index ["tenant_id"], name: "index_platform_balance_snapshots_on_tenant_id"
  end

  create_table "receivable_units", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "currency", default: "BRL"
    t.date "expected_on"
    t.string "external_id"
    t.decimal "fee_amount", precision: 15, scale: 2, default: "0.0"
    t.decimal "gross_amount", precision: 15, scale: 2, default: "0.0"
    t.bigint "invoice_id"
    t.jsonb "metadata", default: {}
    t.decimal "net_amount", precision: 15, scale: 2, default: "0.0"
    t.bigint "order_id"
    t.bigint "platform_account_id"
    t.date "released_on"
    t.string "status", default: "pending", null: false
    t.bigint "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.index ["expected_on"], name: "index_receivable_units_on_expected_on"
    t.index ["invoice_id"], name: "index_receivable_units_on_invoice_id"
    t.index ["order_id"], name: "index_receivable_units_on_order_id"
    t.index ["platform_account_id"], name: "index_receivable_units_on_platform_account_id"
    t.index ["status"], name: "index_receivable_units_on_status"
    t.index ["tenant_id", "external_id"], name: "index_receivable_units_on_tenant_id_and_external_id", unique: true
    t.index ["tenant_id"], name: "index_receivable_units_on_tenant_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "expires_at", null: false
    t.string "ip_address"
    t.datetime "last_used_at"
    t.datetime "revoked_at"
    t.string "token_digest", null: false
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.bigint "user_id", null: false
    t.index ["expires_at"], name: "index_sessions_on_expires_at"
    t.index ["token_digest"], name: "index_sessions_on_token_digest", unique: true
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "tenant_users", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "role", default: "member", null: false
    t.bigint "tenant_id", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["role"], name: "index_tenant_users_on_role"
    t.index ["tenant_id", "user_id"], name: "index_tenant_users_on_tenant_id_and_user_id", unique: true
    t.index ["tenant_id"], name: "index_tenant_users_on_tenant_id"
    t.index ["user_id"], name: "index_tenant_users_on_user_id"
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
    t.string "email", null: false
    t.datetime "last_login_at"
    t.string "name", null: false
    t.string "password_digest"
    t.string "status", default: "active", null: false
    t.datetime "updated_at", null: false
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["status"], name: "index_users_on_status"
  end

  add_foreign_key "certificados_digitais", "tenants"
  add_foreign_key "conciliacao_registros", "conciliation_runs"
  add_foreign_key "conciliacao_registros", "financial_entries"
  add_foreign_key "conciliacao_registros", "payout_batches"
  add_foreign_key "conciliacao_registros", "receivable_units"
  add_foreign_key "conciliacao_registros", "tenants"
  add_foreign_key "conciliation_runs", "platform_accounts"
  add_foreign_key "conciliation_runs", "tenants"
  add_foreign_key "convites", "tenants"
  add_foreign_key "convites", "users", column: "convidado_por_id"
  add_foreign_key "devolucoes", "invoices"
  add_foreign_key "devolucoes", "invoices", column: "return_invoice_id"
  add_foreign_key "devolucoes", "orders"
  add_foreign_key "devolucoes", "platform_accounts"
  add_foreign_key "devolucoes", "tenants"
  add_foreign_key "divergence_reports", "financial_entries"
  add_foreign_key "divergence_reports", "tenants"
  add_foreign_key "financial_entries", "conciliacao_registros"
  add_foreign_key "financial_entries", "financial_entries", column: "reversal_of_id"
  add_foreign_key "financial_entries", "invoices"
  add_foreign_key "financial_entries", "orders"
  add_foreign_key "financial_entries", "platform_accounts"
  add_foreign_key "financial_entries", "tenants"
  add_foreign_key "financial_entry_allocations", "financial_entries"
  add_foreign_key "financial_entry_allocations", "invoices"
  add_foreign_key "financial_entry_allocations", "orders"
  add_foreign_key "financial_entry_allocations", "payout_batches"
  add_foreign_key "financial_entry_allocations", "receivable_units"
  add_foreign_key "financial_entry_allocations", "tenants"
  add_foreign_key "integration_settings", "tenants"
  add_foreign_key "integration_settings", "users", column: "updated_by_id"
  add_foreign_key "invoices", "orders"
  add_foreign_key "invoices", "tenants"
  add_foreign_key "leituras_sefaz", "tenants"
  add_foreign_key "marketplace_credentials", "platform_accounts"
  add_foreign_key "marketplace_credentials", "tenants"
  add_foreign_key "oauth_states", "platform_accounts"
  add_foreign_key "oauth_states", "tenants"
  add_foreign_key "oauth_states", "users"
  add_foreign_key "omie_financial_mappings", "financial_entries"
  add_foreign_key "omie_financial_mappings", "tenants"
  add_foreign_key "orders", "platform_accounts"
  add_foreign_key "orders", "tenants"
  add_foreign_key "payout_batches", "financial_entries"
  add_foreign_key "payout_batches", "platform_accounts"
  add_foreign_key "payout_batches", "tenants"
  add_foreign_key "platform_accounts", "tenants"
  add_foreign_key "platform_balance_snapshots", "platform_accounts"
  add_foreign_key "platform_balance_snapshots", "tenants"
  add_foreign_key "receivable_units", "invoices"
  add_foreign_key "receivable_units", "orders"
  add_foreign_key "receivable_units", "platform_accounts"
  add_foreign_key "receivable_units", "tenants"
  add_foreign_key "sessions", "users"
  add_foreign_key "tenant_users", "tenants"
  add_foreign_key "tenant_users", "users"
end
