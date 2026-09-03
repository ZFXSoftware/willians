import { Activity, Clock, RefreshCw } from "lucide-react"

import {
  fetchFilas,
  fetchProcessos,
  NOMES_DE_JOB,
  type ExecucaoConciliacaoHistorico,
} from "../../api/processos"
import { useResource } from "../../hooks/useResource"
import { dataHoraBR, desde } from "../../lib/format"
import { Carregando, ErroAoCarregar, Selo, Vazio } from "../../components/Estados"

// Ciclo parado é indistinguível de ciclo ocioso quando não se olha o relógio.
//
// Aconteceu de verdade: a conciliação parou em 29/08 e ninguém percebeu por
// dias, porque a tela seguia mostrando os números daquele dia com a mesma cara
// de sempre. Depois de algumas horas sem execução, isso deixa de ser normal.
const HORAS_ATE_SUSPEITAR = 6

function paradaHaMuito(ultima: string | null): boolean {
  if (!ultima) return true

  return Date.now() - new Date(ultima).getTime() > HORAS_ATE_SUSPEITAR * 3600 * 1000
}

export default function Processes() {
  const processos = useResource(fetchProcessos)
  // A fila e o histórico vêm de lugares diferentes — Redis e Postgres — e a
  // fila pode estar fora do ar sem o histórico estar. Recursos separados para
  // que uma falha não apague a outra metade da tela.
  const filas = useResource(fetchFilas)

  const dados = processos.data
  const fila = filas.data

  const emAndamento = [
    ...(fila?.ativos ?? []).map((j) => ({ ...j, estado: "rodando" as const })),
    ...(fila?.esperando ?? []).map((j) => ({ ...j, estado: "na fila" as const })),
  ]

  function recarregar() {
    processos.reload()
    filas.reload()
  }

  return (
    <div className="space-y-6">
      <div className="flex flex-col lg:flex-row lg:items-center lg:justify-between gap-4">
        <div>
          <p className="text-zinc-400 text-sm">Operação</p>
          <h1 className="text-3xl font-bold tracking-tight mt-1">Processos</h1>
          <p className="text-sm text-zinc-400 mt-2 max-w-2xl">
            O que está rodando agora e o que já rodou. Antes de disparar uma
            conciliação, confira aqui: o processamento é um de cada vez, e
            enfileirar de novo só faz esperar.
          </p>
        </div>

        <button
          onClick={recarregar}
          className="flex items-center gap-2 bg-zinc-900 border border-zinc-800 hover:border-zinc-600 px-4 py-3 rounded-xl text-sm transition shrink-0"
        >
          <RefreshCw size={15} />
          Atualizar
        </button>
      </div>

      {/* O aviso que faltava. Sem ele, ciclo morto e sistema ocioso têm a
          mesma aparência — e os números da conciliação continuam na tela
          parecendo atuais. */}
      {dados && paradaHaMuito(dados.ultima_conciliacao) && emAndamento.length === 0 && (
        <div className="bg-red-500/10 border border-red-500/20 rounded-2xl px-5 py-4 text-sm text-red-200">
          <strong>A conciliação não roda há mais de {HORAS_ATE_SUSPEITAR} horas.</strong>{" "}
          {dados.ultima_conciliacao
            ? `A última terminou ${desde(dados.ultima_conciliacao)}.`
            : "Não há registro de nenhuma execução."}{" "}
          O ciclo automático roda a cada 5 minutos — se ele estivesse de pé,
          haveria execução recente. Os números da tela de conciliação são
          daquela data, não de agora.
        </div>
      )}

      <div className="bg-zinc-900 border border-zinc-800 rounded-3xl p-6 shadow-xl">
        <div className="flex items-center gap-3 mb-5">
          <Activity size={18} className="text-zinc-300" />
          <h2 className="font-semibold text-lg">Acontecendo agora</h2>
        </div>

        {filas.error ? (
          <p className="text-sm text-red-300">
            Não consegui ler a fila: {filas.error}. O histórico abaixo continua
            valendo.
          </p>
        ) : emAndamento.length === 0 ? (
          <p className="text-sm text-zinc-400">
            Nada em execução. Um disparo agora começa na hora.
          </p>
        ) : (
          <div className="space-y-2">
            {emAndamento.map((job) => (
              <div
                key={job.id}
                className="flex flex-wrap items-center justify-between gap-3 border border-zinc-800 rounded-xl px-4 py-3"
              >
                <div>
                  <p className="text-sm font-medium">
                    {NOMES_DE_JOB[job.nome] ?? job.nome}
                    {job.periodo && (
                      <span className="text-zinc-500 font-normal"> · {job.periodo}</span>
                    )}
                  </p>
                  <p className="text-xs text-zinc-500 mt-0.5">
                    {job.iniciado_em
                      ? `começou ${desde(job.iniciado_em)}`
                      : `na fila desde ${desde(job.criado_em)}`}
                    {job.tentativa > 0 && ` · ${job.tentativa}ª tentativa`}
                  </p>
                </div>

                <Selo
                  status={job.estado === "rodando" ? "processing" : "pending"}
                  texto={job.estado}
                />
              </div>
            ))}
          </div>
        )}

        {/* Fila compartilhada: dá para estar esperando sem nenhum job seu na
            frente, e sem isso a espera não tem explicação. */}
        {(fila?.total_na_fila?.waiting ?? 0) > emAndamento.length && (
          <p className="text-xs text-zinc-500 mt-4">
            A fila é compartilhada entre organizações: {fila?.total_na_fila?.waiting} job(s)
            aguardando no total.
          </p>
        )}
      </div>

      <div className="bg-zinc-900 border border-zinc-800 rounded-3xl shadow-xl overflow-hidden">
        <div className="flex items-center gap-3 p-6 pb-4">
          <Clock size={18} className="text-zinc-300" />
          <h2 className="font-semibold text-lg">Conciliações recentes</h2>
        </div>

        {processos.loading ? (
          <Carregando />
        ) : processos.error ? (
          <div className="p-5">
            <ErroAoCarregar mensagem={processos.error} onRetry={processos.reload} />
          </div>
        ) : dados && dados.conciliacoes.length === 0 ? (
          <Vazio
            titulo="Nenhuma execução registrada"
            descricao="Assim que a conciliação rodar, cada execução aparece aqui com o que ela encontrou."
          />
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full min-w-[760px] text-sm">
              <thead className="bg-zinc-950/80 text-zinc-400 text-xs uppercase tracking-wide">
                <tr>
                  <th className="text-left font-medium px-4 py-3">Status</th>
                  <th className="text-left font-medium px-4 py-3">Período</th>
                  <th className="text-right font-medium px-4 py-3">Repasses</th>
                  <th className="text-right font-medium px-4 py-3">Conferidos</th>
                  <th className="text-right font-medium px-4 py-3">Divergentes</th>
                  <th className="text-right font-medium px-4 py-3">Duração</th>
                  <th className="text-left font-medium px-4 py-3">Quando</th>
                </tr>
              </thead>

              <tbody>
                {dados?.conciliacoes.map((run) => (
                  <Linha key={run.id} run={run} />
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>

      {dados?.fiscal && (
        <div className="bg-zinc-900 border border-zinc-800 rounded-3xl p-6 shadow-xl">
          <h2 className="font-semibold text-lg mb-4">Rotina fiscal</h2>

          <div className="grid md:grid-cols-2 gap-4 text-sm">
            <Carimbo titulo="Última importação do Tiny" dados={dados.fiscal.importacao} />
            <Carimbo titulo="Último envio ao OMIE" dados={dados.fiscal.envio_ao_omie} />
          </div>
        </div>
      )}
    </div>
  )
}

function Linha({ run }: { run: ExecucaoConciliacaoHistorico }) {
  return (
    <>
      <tr className="border-t border-zinc-800">
        <td className="px-4 py-3">
          <Selo status={run.status} texto={run.status} />
        </td>
        <td className="px-4 py-3 text-zinc-300">{run.periodo || "—"}</td>
        <td className="px-4 py-3 text-right">{run.repasses ?? "—"}</td>
        <td className="px-4 py-3 text-right text-emerald-400">{run.conferidos ?? "—"}</td>
        <td className="px-4 py-3 text-right text-red-400">{run.divergentes ?? "—"}</td>
        <td className="px-4 py-3 text-right text-zinc-400">
          {run.duracao_s != null ? `${run.duracao_s}s` : "—"}
        </td>
        <td className="px-4 py-3 text-zinc-400">
          {run.terminada_em ? dataHoraBR(run.terminada_em) : "não terminou"}
        </td>
      </tr>

      {run.erro && (
        <tr className="border-t border-zinc-900">
          <td />
          <td colSpan={6} className="px-4 pb-3 text-xs text-red-300">
            {run.erro}
          </td>
        </tr>
      )}
    </>
  )
}

// Importação e envio não têm tabela de execução: o desfecho fica carimbado na
// empresa. Mostrar o carimbo cru é feio, mas é honesto — e é o que existe.
function Carimbo({ titulo, dados }: { titulo: string; dados: Record<string, unknown> | null }) {
  return (
    <div className="border border-zinc-800 rounded-xl px-4 py-3">
      <p className="text-zinc-500 text-xs">{titulo}</p>

      {dados ? (
        <div className="mt-2 space-y-1">
          {Object.entries(dados).map(([chave, valor]) => (
            <p key={chave} className="text-xs text-zinc-300">
              <span className="text-zinc-500">{chave.replace(/_/g, " ")}: </span>
              {chave === "em" ? desde(String(valor)) : String(valor ?? "—")}
            </p>
          ))}
        </div>
      ) : (
        <p className="text-sm text-zinc-400 mt-1">nunca rodou</p>
      )}
    </div>
  )
}
