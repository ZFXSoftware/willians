import { Fragment, useState } from "react"
import { AlertTriangle, CheckCircle2, ChevronDown, Clock } from "lucide-react"

import {
  fetchDivergencias,
  type Divergencia,
  type FiltrosDivergencias,
} from "../../api/divergencias"
import PainelContestacao from "../../components/PainelContestacao"
import { useResource } from "../../hooks/useResource"
import { brl, dataBR, rotulo } from "../../lib/format"
import { Carregando, ErroAoCarregar, Selo, Vazio } from "../../components/Estados"

const STATUS = ["open", "analyzing", "resolved", "ignored"]

const ICONES: Record<string, typeof AlertTriangle> = {
  open: AlertTriangle,
  analyzing: Clock,
  resolved: CheckCircle2,
  ignored: CheckCircle2,
}

export default function Divergences() {
  const [filtros, setFiltros] = useState<FiltrosDivergencias>({ page: 1 })

  const [contestando, setContestando] = useState<number | null>(null)

  // O painel devolve a divergência já atualizada; guardar aqui evita recarregar
  // a lista inteira a cada protocolo registrado.
  const [alteradas, setAlteradas] = useState<Record<number, Divergencia>>({})

  const { data, loading, error, reload } = useResource(
    () => fetchDivergencias(filtros),
    [JSON.stringify(filtros)],
  )

  const resumo = data?.resumo

  const stats = [
    {
      titulo: "Divergências abertas",
      valor: String(resumo?.por_status?.open ?? 0),
      tom: "text-red-400",
    },
    {
      titulo: "Em análise",
      valor: String(resumo?.por_status?.analyzing ?? 0),
      tom: "text-yellow-400",
    },
    {
      titulo: "Resolvidas no mês",
      valor: String(resumo?.resolvidas_no_mes ?? 0),
      tom: "text-emerald-400",
    },
    {
      titulo: "Valor em disputa",
      valor: brl(resumo?.valor_em_disputa),
      tom: "text-white",
    },
  ]

  return (
    <div className="space-y-6">
      <div className="flex flex-col lg:flex-row lg:items-center lg:justify-between gap-4">
        <div>
          <p className="text-zinc-400 text-sm">Conciliação Financeira</p>
          <h1 className="text-3xl font-bold tracking-tight mt-1">Divergências</h1>
        </div>

        <div className="relative">
          <select
            value={filtros.status ?? ""}
            onChange={(e) =>
              setFiltros({ status: e.target.value || undefined, page: 1 })
            }
            className="appearance-none bg-zinc-900 border border-zinc-800 rounded-xl pl-4 pr-9 py-3 text-sm outline-none focus:border-zinc-600"
          >
            <option value="">Todos status</option>
            {STATUS.map((s) => (
              <option key={s} value={s}>
                {rotulo(s)}
              </option>
            ))}
          </select>
          <ChevronDown
            size={15}
            className="absolute right-3 top-1/2 -translate-y-1/2 text-zinc-500 pointer-events-none"
          />
        </div>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-4 gap-4">
        {stats.map((item) => (
          <div
            key={item.titulo}
            className="bg-zinc-900 border border-zinc-800 rounded-3xl p-5 shadow-xl"
          >
            <p className="text-sm text-zinc-400">{item.titulo}</p>
            <h2 className={`text-2xl font-bold mt-3 ${item.tom}`}>{item.valor}</h2>
          </div>
        ))}
      </div>

      <div className="bg-zinc-900 border border-zinc-800 rounded-3xl overflow-hidden shadow-2xl">
        <div className="p-5 border-b border-zinc-800">
          <h2 className="text-lg font-semibold">Casos de divergência</h2>
          <p className="text-zinc-400 text-sm mt-1">
            Diferenças entre o esperado no OMIE e o recebido da plataforma.
          </p>
        </div>

        {loading ? (
          <Carregando />
        ) : error ? (
          <div className="p-5">
            <ErroAoCarregar mensagem={error} onRetry={reload} />
          </div>
        ) : data && data.items.length === 0 ? (
          <Vazio
            titulo="Nenhuma divergência"
            descricao="Quando um repasse não bater com os títulos do OMIE, o caso aparece aqui."
          />
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full min-w-[900px]">
              <thead className="bg-zinc-950/80 text-zinc-400 text-sm">
                <tr>
                  <th className="text-left font-medium px-6 py-4">Caso</th>
                  <th className="text-left font-medium px-6 py-4">Status</th>
                  <th className="text-left font-medium px-6 py-4">Tipo</th>
                  <th className="text-left font-medium px-6 py-4">Referência</th>
                  <th className="text-left font-medium px-6 py-4">Plataforma</th>
                  <th className="text-right font-medium px-6 py-4">Esperado</th>
                  <th className="text-right font-medium px-6 py-4">Recebido</th>
                  <th className="text-right font-medium px-6 py-4">Diferença</th>
                  <th className="text-left font-medium px-6 py-4">Data</th>
                  <th className="text-right font-medium px-6 py-4">Contestação</th>
                </tr>
              </thead>

              <tbody>
                {data?.items.map((original) => {
                  const row = alteradas[original.id] ?? original
                  const Icone = ICONES[row.status] ?? AlertTriangle
                  const dif = Number(row.diferenca ?? 0)
                  const aberta = contestando === row.id

                  return (
                    <Fragment key={row.id}>
                    <tr
                      className="border-t border-zinc-800 hover:bg-zinc-800/30 transition"
                    >
                      <td className="px-6 py-5 text-zinc-400">DIV-{row.id}</td>
                      <td className="px-6 py-5">
                        <span className="inline-flex items-center gap-1.5">
                          <Icone size={13} className="text-zinc-400" />
                          <Selo status={row.status} texto={rotulo(row.status)} />
                        </span>
                      </td>
                      <td className="px-6 py-5 text-zinc-300">{rotulo(row.tipo)}</td>
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
                          dif > 0 ? "text-emerald-400" : "text-red-400"
                        }`}
                      >
                        {brl(row.diferenca)}
                      </td>
                      <td className="px-6 py-5 text-zinc-400">{dataBR(row.data)}</td>
                      <td className="px-6 py-5 text-right">
                        <button
                          onClick={() => setContestando(aberta ? null : row.id)}
                          className="text-sm text-zinc-400 hover:text-white transition whitespace-nowrap"
                        >
                          {row.contestacao?.protocolo
                            ? row.contestacao.protocolo
                            : aberta
                              ? "fechar"
                              : "Contestar"}
                        </button>
                      </td>
                    </tr>

                    {aberta && (
                      <tr className="border-t border-zinc-800 bg-zinc-950/40">
                        <td colSpan={10} className="px-6 pb-6">
                          <PainelContestacao
                            divergencia={row}
                            onFechar={() => setContestando(null)}
                            onAtualizar={(d) =>
                              setAlteradas((atual) => ({ ...atual, [d.id]: d }))
                            }
                          />
                        </td>
                      </tr>
                    )}
                    </Fragment>
                  )
                })}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  )
}
