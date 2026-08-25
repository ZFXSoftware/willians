class AddLastSyncStatusToPlatformAccounts < ActiveRecord::Migration[8.1]
  # Como foi a última sincronização: "ok", "pendente" ou "falha".
  #
  # Existia só `last_sync_error`, e a ausência dele significava sucesso. Isso
  # não comporta o terceiro caso real: o marketplace ainda está PREPARANDO o
  # dado (o relatório de liberações do Mercado Pago é gerado de forma
  # assíncrona). Sem uma coluna para dizê-lo, "ainda não trouxe" era
  # indistinguível de "não havia nada para trazer" — e a tela anunciava
  # "importação concluída — 0 lançamento(s)" para uma importação que não
  # aconteceu.
  #
  # Sem valor padrão: nulo é a verdade para as contas anteriores a esta
  # migração, e inventar "ok" para elas seria repetir o erro que ela conserta.
  def change
    add_column :platform_accounts, :last_sync_status, :string
  end
end
