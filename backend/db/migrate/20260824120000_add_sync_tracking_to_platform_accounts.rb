class AddSyncTrackingToPlatformAccounts < ActiveRecord::Migration[8.1]
  def change
    # Quando a ingestão RODOU — que não é a mesma coisa que quando o último
    # lançamento entrou. A tela mostrava o máximo de `financial_entries.
    # created_at`, e por isso uma conta sem venda nova parecia nunca ter
    # sincronizado. Pior: sem marcar a tentativa, o agendador de 5 em 5 minutos
    # varreria o marketplace de novo toda vez, mesmo sem nada para trazer.
    add_column :platform_accounts, :last_synced_at, :datetime

    # A falha da última tentativa, para aparecer no card em vez de morrer no log.
    add_column :platform_accounts, :last_sync_error, :string

    # O agendador procura quem está vencido; o índice evita varrer a tabela.
    add_index :platform_accounts, :last_synced_at
  end
end
