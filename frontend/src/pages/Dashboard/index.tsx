import { ArrowDownRight, ArrowUpRight } from "lucide-react"

import { fetchPainel } from "../../api/painel"
import { useResource } from "../../hooks/useResource"
import { brl, dataBR, desde, numero, rotulo } from "../../lib/format"
import { Carregando, ErroAoCarregar, Selo, Vazio } from "../../components/Estados"

export default function Dashboard() {
  const { data, loading, error, reload } = useResource(fetchPainel)

  if (loading) return <Carregando />
  if (error) return <ErroAoCarregar mensagem={error} onRetry={reload} />
  if (!data) return null

  const kpis = [
    { titulo: "Saldo Virtual", valor: brl(data.saldo_virtual), nota: "liquidado nas plataformas" },
    { titulo: "A Receber", valor: brl(data.a_receber), nota: "recebíveis em aberto" },
    { titulo: "Conciliado", valor: brl(data.conciliado), nota: "repasses casados" },
    {
      titulo: "Divergências",
      valor: brl(data.divergencias),
      nota: `${data.divergencias_abertas} em aberto`,
      alerta: data.divergencias_abertas > 0,
    },
  ]

  return (
    <div className="space-y-6">
      <div className="flex flex-col lg:flex-row lg:items-center lg:justify-between gap-4">
        <div>
          <p className="text-zinc-400 text-sm">Conciliação Financeira</p>
          <h1 className="text-3xl font-bold tracking-tight mt-1">Dashboard</h1>
        </div>

        <div className="text-sm text-zinc-400">
          {data.contas_conectadas} de {data.total_contas} conta(s) conectada(s)
          {" · "}
          última conciliação {desde(data.ultima_conciliacao)}
        </div>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-4 gap-4">
        {kpis.map((kpi) => (
          <div
            key={kpi.titulo}
            className="bg-zinc-900 border border-zinc-800 rounded-3xl p-5 shadow-xl"
          >
            <p className="text-sm text-zinc-400">{kpi.titulo}</p>
            <h2
              className={`text-2xl font-bold mt-3 ${kpi.alerta ? "text-red-400" : ""}`}
            >
              {kpi.valor}
            </h2>
            <p className="text-xs text-zinc-500 mt-2">{kpi.nota}</p>
          </div>
        ))}
      </div>

      <div className="bg-zinc-900 border border-zinc-800 rounded-3xl overflow-hidden shadow-2xl">
        <div className="p-5 border-b border-zinc-800">
          <h2 className="text-lg font-semibold">Últimas movimentações</h2>
          <p className="text-zinc-400 text-sm mt-1">
            Lançamentos mais recentes no razão financeiro.
          </p>
        </div>

        {data.ultimas_movimentacoes.length === 0 ? (
          <Vazio
            titulo="Nenhuma movimentação ainda"
            descricao="Conecte uma conta de marketplace para começar a importar os lançamentos financeiros."
          />
        ) : (
          <div className="overflow-x-auto">
            <table className="w-full min-w-[720px]">
              <thead className="bg-zinc-950/80 text-zinc-400 text-sm">
                <tr>
                  <th className="text-left font-medium px-6 py-4">Data</th>
                  <th className="text-left font-medium px-6 py-4">Descrição</th>
                  <th className="text-left font-medium px-6 py-4">Plataforma</th>
                  <th className="text-right font-medium px-6 py-4">Valor</th>
                  <th className="text-left font-medium px-6 py-4">Status</th>
                </tr>
              </thead>

              <tbody>
                {data.ultimas_movimentacoes.map((m) => (
                  <tr
                    key={m.id}
                    className="border-t border-zinc-800 hover:bg-zinc-800/30 transition"
                  >
                    <td className="px-6 py-4 text-zinc-400">{dataBR(m.data)}</td>
                    <td className="px-6 py-4 font-medium">{m.descricao}</td>
                    <td className="px-6 py-4 text-zinc-300">
                      {rotulo(m.plataforma)}
                    </td>
                    <td
                      className={`px-6 py-4 text-right font-medium ${
                        m.direcao === "credit" ? "text-emerald-400" : "text-red-400"
                      }`}
                    >
                      <span className="inline-flex items-center gap-1 justify-end">
                        {m.direcao === "credit" ? (
                          <ArrowUpRight size={14} />
                        ) : (
                          <ArrowDownRight size={14} />
                        )}
                        {brl(numero(m.valor))}
                      </span>
                    </td>
                    <td className="px-6 py-4">
                      <Selo status={m.status} texto={rotulo(m.status)} />
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </div>
    </div>
  )
}
