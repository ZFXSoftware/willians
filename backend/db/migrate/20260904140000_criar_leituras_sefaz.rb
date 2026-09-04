class CriarLeiturasSefaz < ActiveRecord::Migration[8.1]
  def change
    create_table :leituras_sefaz do |t|
      t.references :tenant, null: false, foreign_key: true

      # Onde a nossa leitura parou.
      #
      # A distribuição de DF-e é uma FILA INCREMENTAL: cada consumidor guarda
      # o próprio marcador e pede o que vem depois dele. Recomeçar do zero é
      # "consumo indevido" e custa uma hora de bloqueio — foi o que aconteceu
      # na primeira chamada, por não haver onde guardar isto.
      t.bigint :ultimo_nsu, null: false, default: 0

      # O maior NSU que a SEFAZ diz existir. A distância entre os dois é o
      # quanto falta ler.
      t.bigint :max_nsu

      t.datetime :consultado_em

      # Quando a SEFAZ manda esperar, esperamos. Insistir antes da hora
      # transforma penalidade ocasional em bloqueio recorrente.
      t.datetime :bloqueado_ate

      t.string :ultimo_status

      t.string :ultimo_motivo

      t.jsonb :metadata, null: false, default: {}

      t.timestamps
    end

    add_index :leituras_sefaz, :tenant_id, unique: true, name: "idx_leitura_sefaz_por_empresa"
  end
end
