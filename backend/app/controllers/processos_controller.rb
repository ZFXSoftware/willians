# O histórico do que o sistema executou.
#
# A fila (no gateway) diz o que está acontecendo AGORA; aqui está o que já
# aconteceu e como terminou. Sem os dois lados, "processar" é um botão que
# responde "enfileirado" e some — e a única forma de saber se deu certo era
# comparar contadores de tempos em tempos, ou abrir o Postgres.
#
# Foi o que aconteceu de fato: a conciliação parou de rodar em 29/08 e ninguém
# percebeu por dias, porque a tela mostrava alegremente os números daquele dia.
class ProcessosController < ApplicationController
  before_action :require_tenant!

  LIMITE = 20

  def index
    render json: {
      conciliacoes: conciliacoes,
      fiscal: fiscal,
      # Há quanto tempo a última conciliação terminou. É o número que denuncia
      # ciclo morto: se o agendador roda a cada 5 minutos e isto marca dias, o
      # que está na tela não é resultado, é fóssil.
      ultima_conciliacao: ConciliationRun.where(tenant_id: current_tenant.id).maximum(:finished_at)
    }
  end

  private

  def conciliacoes
    ConciliationRun
      .where(tenant_id: current_tenant.id)
      .order(started_at: :desc)
      .limit(LIMITE)
      .map do |run|
        {
          id: run.id,
          status: run.status,
          plataforma: run.platform,
          iniciada_em: run.started_at,
          terminada_em: run.finished_at,
          duracao_s: duracao(run),
          repasses: run.total_entries,
          conferidos: run.matches_found,
          divergentes: run.divergences_found,
          periodo: [ run.metadata["start_date"], run.metadata["end_date"] ].compact_blank.join(" a "),
          erro: run.metadata["error"]
        }
      end
  end

  # Importação do Tiny e envio ao OMIE não têm tabela de execução: o desfecho de
  # cada um fica carimbado na empresa. Vêm aqui para a tela ter UM lugar que
  # responde "o que o sistema andou fazendo".
  def fiscal
    {
      importacao: current_tenant.metadata["tiny_ultima_importacao"],
      envio_ao_omie: current_tenant.metadata["omie_envio_saude"]
    }
  end

  def duracao(run)
    return unless run.started_at && run.finished_at

    (run.finished_at - run.started_at).round
  end
end
