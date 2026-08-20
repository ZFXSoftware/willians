class AddPlatformSideToBalanceSnapshots < ActiveRecord::Migration[8.1]
  def change
    # O snapshot só guardava o NOSSO saldo, calculado do razão. O briefing 2.4
    # pede o espelho: o saldo que a plataforma diz ter, lado a lado, para que a
    # diferença apareça sozinha.
    change_table :platform_balance_snapshots, bulk: true do |t|
      t.decimal :platform_available_balance, precision: 15, scale: 2
      t.decimal :platform_future_balance, precision: 15, scale: 2
      t.decimal :platform_total_balance, precision: 15, scale: 2
      t.decimal :difference_amount, precision: 15, scale: 2
      t.string :platform_source
    end

    # Um snapshot por conta por dia: rodar a conferência duas vezes no mesmo
    # dia atualiza o registro em vez de empilhar leituras do mesmo saldo.
    # As duplicatas que já existem são resolvidas mantendo a mais recente.
    reversible do |dir|
      dir.up do
        execute <<~SQL
          DELETE FROM platform_balance_snapshots a
          USING platform_balance_snapshots b
          WHERE a.platform_account_id = b.platform_account_id
            AND a.snapshot_date = b.snapshot_date
            AND a.id < b.id
        SQL
      end
    end

    add_index :platform_balance_snapshots, %i[platform_account_id snapshot_date],
              unique: true, name: "idx_balance_snapshots_conta_data"

    # Divergência de saldo não é de um lançamento: é da conta inteira num dia.
    change_column_null :divergence_reports, :financial_entry_id, true

    # O índice único existente cobre só divergências com lançamento (NULLs são
    # distintos entre si no Postgres). Este cobre as demais, pela chave que o
    # serviço monta.
    add_index :divergence_reports,
              "tenant_id, divergence_type, (metadata->>'chave')",
              unique: true,
              where: "financial_entry_id IS NULL",
              name: "idx_divergence_reports_sem_lancamento"
  end
end
