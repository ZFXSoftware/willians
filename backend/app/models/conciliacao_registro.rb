class ConciliacaoRegistro < ApplicationRecord
  belongs_to :tenant,
             optional: true

  belongs_to :conciliation_run,
             optional: true

  belongs_to :financial_entry,
             optional: true

  belongs_to :receivable_unit,
             optional: true

  belongs_to :payout_batch,
             optional: true

  # O lado inverso da FK financial_entries.conciliacao_registro_id. Nullify e
  # não destroy: desfazer uma conciliação não pode apagar o LANÇAMENTO, que é
  # o fato financeiro — some o vínculo, fica o dinheiro.
  has_many :financial_entries,
           dependent: :nullify,
           inverse_of: :conciliacao_registro

  # A conciliação GRAVA um registro por repasse a cada execução, de propósito:
  # é o histórico de como aquele repasse foi conferido ao longo do tempo.
  #
  # A tela, porém, mostra estado atual — "cada linha compara um repasse com os
  # títulos do OMIE". Sem este recorte, rodar a conciliação três vezes exibia o
  # mesmo repasse três vezes, e o resumo contava tudo em triplicado.
  #
  # O COALESCE existe para o registro sem lote: `-id` é sempre negativo, então
  # nunca colide com um payout_batch_id de verdade e cada órfão fica por si.
  # Recebe o tenant em vez de encadear em cima da relação de fora: a subconsulta
  # precisa de ordenação PRÓPRIA (o DISTINCT ON exige), e herdar o `order` e o
  # `includes` da listagem quebraria o recorte sem avisar.
  def self.ids_dos_ultimos(tenant_id)
    where(tenant_id: tenant_id)
      .select("DISTINCT ON (COALESCE(payout_batch_id, -id)) id")
      .reorder(Arel.sql("COALESCE(payout_batch_id, -id), conciliated_at DESC NULLS LAST, id DESC"))
  end

  enum :status, {
    pending: "pending",
    matched: "matched",
    divergent: "divergent",
    manual_review: "manual_review",
    resolved: "resolved"
  }

  enum :match_type, {
    exact: "exact",
    approximate: "approximate",
    batch: "batch",
    manual: "manual"
  }

  validates :status,
            presence: true
end
