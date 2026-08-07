import { useState } from "react"
import { RefreshCw, Search } from "lucide-react"

import {
  fetchRegistros,
  processarConciliacao,
  type FiltrosRegistros,
} from "../../api/conciliacoes"
import { errorMessage } from "../../api/client"
import { useResource } from "../../hooks/useResource"
import { brl, dataHoraBR, desde, rotulo } from "../../lib/format"
import { Carregando, ErroAoCarregar, Selo, Vazio } from "../../components/Estados"

const PLATAFORMAS = ["mercado_livre", "shopee", "amazon", "magalu"]

const STATUS = ["matched", "divergent", "manual_review", "pending"]

export default function ReconciliationDashboard() {
  const [filtros, setFiltros] = useState<FiltrosRegistros>({ page: 1 })
  const [busca, setBusca] = useState("")
  const [processando, setProcessando] = useState(false)
  const [aviso, setAviso] = useState<string | null>(null)

  const { data, loading, error, reload } = useResource(
    () => fetchRegistros(filtros),
    [JSON.stringify(filtros)],
  )

  function aplicar(mudanca: Partial<FiltrosRegistros>) {
    setFiltros((atual) => ({ ...atual, ...mudanca, page: 1 }))
  }

  async function disparar() {
    setProcessando(true)
    setAviso(null)

    try {
      const { job_id } = await processarConciliacao()
      setAviso(`Conciliação enfileirada (job ${job_id}). Atualize em instantes.`)
    } catch (e) {
      setAviso(errorMessage(e, "Não foi possível disparar a conciliação"))
    } finally {
      setProcessando(false)
    }
  }

  const resumo = data?.resumo

  const stats = [
    { titulo: "Total Conciliado", valor: brl(resumo?.total_conciliado) },
    { titulo: "Divergências abertas", valor: String(resumo?.divergencias_abertas ?? 0) },
    { titulo: "Execuções hoje", valor: String(resumo?.execucoes_hoje ?? 0) },
    { titulo: "Última execução", valor: desde(resumo?.ultima_execucao) },
  ]

  return (
    <div className="space-y-6">
      <div className="flex flex-col lg:flex-row lg:items-center lg:justify-between gap-4">
        <div>
          <p className="text-zinc-400 text-sm">Conciliação Financeira</p>
          <h1 className="text-3xl font-bold tracking-tight mt-1">
            Central de Conciliação
          </h1>
        </div>

        <div className="flex flex-wrap gap-3">
          <select
            value={filtros.plataforma ?? ""}
            onChange={(e) => aplicar({ plataforma: e.target.value || undefined })}
            className="bg-zinc-900 border border-zinc-800 rounded-xl px-4 py-3 text-sm outline-none focus:border-zinc-600"
          >
            <option value="">Todas plataformas</option>
            {PLATAFORMAS.map((p) => (
              <option key={p} value={p}>
                {rotulo(p)}
              </option>
            ))}
          </select>

          <button
            onClick={disparar}
            disabled={processando}
            className="flex items-center gap-2 bg-white text-black font-medium px-5 py-3 rounded-xl hover:opacity-90 transition disabled:opacity-50"
          >
            <RefreshCw size={15} className={processando ? "animate-spin" : ""} />
            {processando ? "Enfileirando..." : "Processar Conciliação"}
          </button>
        </div>
      </div>

      {aviso && (
        <div className="bg-zinc-900 border border-zinc-800 rounded-2xl px-5 py-4 text-sm text-zinc-300 flex items-center justify-between gap-4">
          {aviso}
          <button onClick={reload} className="text-zinc-400 hover:text-white shrink-0">
            atualizar
          </button>
        </div>
      )}

      <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-4 gap-4">
        {stats.map((item) => (
          <div
            key={item.titulo}
            className="bg-zinc-900 border border-zinc-800 rounded-3xl p-5 shadow-xl"
          >
            <p className="text-sm text-zinc-400">{item.titulo}</p>
            <h2 className="text-2xl font-bold mt-3">{item.valor}</h2>
          </div>
        ))}
      </div>

      <div className="bg-zinc-900 border border-zinc-800 rounded-3xl overflow-hidden shadow-2xl">
        <div className="flex flex-col lg:flex-row lg:items-center lg:justify-between gap-4 p-5 border-b border-zinc-800">
          <div>
            <h2 className="text-lg font-semibold">Repasses conciliados</h2>
            <p className="text-zinc-400 text-sm mt-1">
              Cada linha compara um repasse da plataforma com os títulos do OMIE.
            </p>
          </div>

          <div className="flex flex-wrap gap-3">
            <form
              onSubmit={(e) => {
                e.preventDefault()
                aplicar({ busca: busca || undefined })
              }}
              className="relative"
            >
              <Search
                size={16}
                className="absolute left-4 top-1/2 -translate-y-1/2 text-zinc-500"
              />
              <input
                value={busca}
                onChange={(e) => setBusca(e.target.value)}
                placeholder="Buscar referência do repasse"
                className="bg-zinc-950 border border-zinc-800 rounded-xl pl-10 pr-4 py-3 text-sm min-w-[260px] outline-none focus:border-zinc-600"
              />
            </form>

            <select
              value={filtros.status ?? ""}
              onChange={(e) => aplicar({ status: e.target.value || undefined })}
              className="bg-zinc-950 border border-zinc-800 rounded-xl px-4 py-3 text-sm outline-none focus:border-zinc-600"
            >
              <option value="">Todos status</option>
              {STATUS.map((s) => (
                <option key={s} value={s}>
                  {rotulo(s)}
                </option>
              ))}
            </select>
          </div>
        </div>

        {loading ? (
          <Carregando />
        ) : error ? (
          <div className="p-5">
            <ErroAoCarregar mensagem={error} onRetry={reload} />
          </div>
        ) : data && data.items.length === 0 ? (
          <Vazio
            titulo="Nenhum repasse conciliado"
            descricao="Assim que houver repasses na janela e títulos correspondentes no OMIE, eles aparecem aqui."
          />
        ) : (
          <>
            <div className="overflow-x-auto">
              <table className="w-full min-w-[900px]">
                <thead className="bg-zinc-950/80 text-zinc-400 text-sm">
                  <tr>
                    <th className="text-left font-medium px-6 py-4">Status</th>
                    <th className="text-left font-medium px-6 py-4">Repasse</th>
                    <th className="text-left font-medium px-6 py-4">Plataforma</th>
                    <th className="text-right font-medium px-6 py-4">Esperado (OMIE)</th>
                    <th className="text-right font-medium px-6 py-4">Recebido</th>
                    <th className="text-right font-medium px-6 py-4">Diferença</th>
                    <th className="text-left font-medium px-6 py-4">Confiança</th>
                    <th className="text-left font-medium px-6 py-4">Data</th>
                  </tr>
                </thead>

                <tbody>
                  {data?.items.map((row) => {
                    const dif = Number(row.diferenca ?? 0)

                    return (
                      <tr
                        key={row.id}
                        className="border-t border-zinc-800 hover:bg-zinc-800/30 transition"
                      >
                        <td className="px-6 py-5">
                          <Selo status={row.status} texto={rotulo(row.status)} />
                        </td>
                        <td className="px-6 py-5 font-medium">
                          {row.referencia ?? "—"}
                        </td>
                        <td className="px-6 py-5 text-zinc-300">
                          {rotulo(row.plataforma)}
                        </td>
                        <td className="px-6 py-5 text-right">
                          {brl(row.valor_esperado)}
                        </td>
                        <td className="px-6 py-5 text-right">
                          {brl(row.valor_recebido)}
                        </td>
                        <td
                          className={`px-6 py-5 text-right font-medium ${
                            dif === 0
                              ? "text-zinc-400"
                              : dif > 0
                                ? "text-emerald-400"
                                : "text-red-400"
                          }`}
                        >
                          {brl(row.diferenca)}
                        </td>
                        <td className="px-6 py-5 text-zinc-400">
                          {Number(row.confianca).toFixed(0)}%
                        </td>
                        <td className="px-6 py-5 text-zinc-400">
                          {dataHoraBR(row.data)}
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>

            {data && data.meta.total_pages > 1 && (
              <div className="flex items-center justify-between p-5 border-t border-zinc-800 text-sm">
                <span className="text-zinc-400">
                  {data.meta.total} registro(s) · página {data.meta.page} de{" "}
                  {data.meta.total_pages}
                </span>

                <div className="flex gap-2">
                  <button
                    disabled={data.meta.page <= 1}
                    onClick={() =>
                      setFiltros((f) => ({ ...f, page: (f.page ?? 1) - 1 }))
                    }
                    className="bg-zinc-800 hover:bg-zinc-700 disabled:opacity-40 px-4 py-2 rounded-lg transition"
                  >
                    Anterior
                  </button>
                  <button
                    disabled={data.meta.page >= data.meta.total_pages}
                    onClick={() =>
                      setFiltros((f) => ({ ...f, page: (f.page ?? 1) + 1 }))
                    }
                    className="bg-zinc-800 hover:bg-zinc-700 disabled:opacity-40 px-4 py-2 rounded-lg transition"
                  >
                    Próxima
                  </button>
                </div>
              </div>
            )}
          </>
        )}
      </div>
    </div>
  )
}
