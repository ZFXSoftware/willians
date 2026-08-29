import { useState } from "react"
import { ArrowDownRight, ArrowUpRight, Search } from "lucide-react"

import {
  fetchLancamentos,
  type FiltrosLancamentos,
} from "../../api/lancamentos"
import { useResource } from "../../hooks/useResource"
import { brl, dataBR, numero, rotulo } from "../../lib/format"
import { Carregando, ErroAoCarregar, Selo, Vazio } from "../../components/Estados"

const TIPOS = ["sale", "fee", "refund", "settlement", "chargeback", "adjustment"]

const PLATAFORMAS = ["mercado_livre", "shopee", "amazon", "magalu"]

export default function Entries() {
  const [filtros, setFiltros] = useState<FiltrosLancamentos>({ page: 1 })
  const [busca, setBusca] = useState("")

  const { data, loading, error, reload } = useResource(
    () => fetchLancamentos(filtros),
    [JSON.stringify(filtros)],
  )

  function aplicar(mudanca: Partial<FiltrosLancamentos>) {
    setFiltros((atual) => ({ ...atual, ...mudanca, page: 1 }))
  }

  const resumo = data?.resumo
  const meta = data?.meta

  return (
    <div className="space-y-6">
      <div>
        <p className="text-zinc-400 text-sm">Conciliação Financeira</p>
        <h1 className="text-3xl font-bold tracking-tight mt-1">Lançamentos</h1>
        <p className="text-sm text-zinc-400 mt-2 max-w-2xl">
          Tudo o que entrou e saiu nas plataformas: vendas pelo bruto, cada taxa
          discriminada e os repasses para o banco. É o razão que a conciliação
          compara com os títulos do OMIE.
        </p>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        {[
          { titulo: "Lançamentos", valor: String(resumo?.total ?? 0), tom: "" },
          { titulo: "Entradas", valor: brl(resumo?.creditos), tom: "text-emerald-400" },
          { titulo: "Saídas", valor: brl(resumo?.debitos), tom: "text-red-400" },
        ].map((item) => (
          <div
            key={item.titulo}
            className="bg-zinc-900 border border-zinc-800 rounded-3xl p-5 shadow-xl"
          >
            <p className="text-sm text-zinc-400">{item.titulo}</p>
            <h2 className={`text-2xl font-bold mt-3 ${item.tom}`}>{item.valor}</h2>
            {/* Os totais são do FILTRO, não do razão inteiro: a pergunta que se
                faz olhando uma lista filtrada é sobre o que está nela. */}
            <p className="text-xs text-zinc-500 mt-2">no filtro atual</p>
          </div>
        ))}
      </div>

      <div className="bg-zinc-900 border border-zinc-800 rounded-3xl overflow-hidden shadow-2xl">
        <div className="flex flex-col lg:flex-row lg:items-center lg:justify-between gap-4 p-5 border-b border-zinc-800">
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
              placeholder="Pedido, pagamento ou referência"
              className="bg-zinc-950 border border-zinc-800 rounded-xl pl-10 pr-4 py-2.5 text-sm min-w-[280px] outline-none focus:border-zinc-600"
            />
          </form>

          <div className="flex flex-wrap gap-3">
            <select
              value={filtros.tipo ?? ""}
              onChange={(e) => aplicar({ tipo: e.target.value || undefined })}
              className="bg-zinc-950 border border-zinc-800 rounded-xl px-4 py-2.5 text-sm outline-none focus:border-zinc-600"
            >
              <option value="">Todos os tipos</option>
              {TIPOS.map((t) => (
                <option key={t} value={t}>
                  {rotulo(t)}
                </option>
              ))}
            </select>

            <select
              value={filtros.plataforma ?? ""}
              onChange={(e) => aplicar({ plataforma: e.target.value || undefined })}
              className="bg-zinc-950 border border-zinc-800 rounded-xl px-4 py-2.5 text-sm outline-none focus:border-zinc-600"
            >
              <option value="">Todas plataformas</option>
              {PLATAFORMAS.map((p) => (
                <option key={p} value={p}>
                  {rotulo(p)}
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
            titulo="Nenhum lançamento"
            descricao="Ajuste os filtros, ou sincronize uma conta de marketplace em Integrações."
          />
        ) : (
          <>
            <div className="overflow-x-auto">
              <table className="w-full min-w-[820px] text-sm">
                <thead className="bg-zinc-950/80 text-zinc-400 text-xs uppercase tracking-wide">
                  <tr>
                    <th className="text-left font-medium px-4 py-3">Data</th>
                    <th className="text-left font-medium px-4 py-3">Lançamento</th>
                    <th className="text-left font-medium px-4 py-3">Plataforma</th>
                    <th className="text-right font-medium px-4 py-3">Valor</th>
                    <th className="text-left font-medium px-4 py-3">Situação</th>
                    <th className="text-left font-medium px-4 py-3">Conciliado</th>
                  </tr>
                </thead>

                <tbody>
                  {data?.items.map((linha) => (
                    <tr
                      key={linha.id}
                      className="border-t border-zinc-800 hover:bg-zinc-800/30 transition"
                    >
                      <td className="px-4 py-3 text-zinc-400">{dataBR(linha.data)}</td>

                      <td className="px-4 py-3">
                        <span className="font-medium">{rotulo(linha.tipo)}</span>
                        <span
                          className="block text-xs text-zinc-500 mt-0.5"
                          title={linha.referencia}
                        >
                          {linha.pedido
                            ? `Pedido ${linha.pedido}`
                            : linha.pagamento
                              ? `Pagamento ${linha.pagamento}`
                              : "Sem identificação da plataforma"}
                        </span>
                      </td>

                      <td className="px-4 py-3 text-zinc-300">{rotulo(linha.plataforma)}</td>

                      <td
                        className={`px-4 py-3 text-right font-medium ${
                          linha.direcao === "credit" ? "text-emerald-400" : "text-red-400"
                        }`}
                      >
                        <span className="inline-flex items-center gap-1 justify-end">
                          {linha.direcao === "credit" ? (
                            <ArrowUpRight size={14} />
                          ) : (
                            <ArrowDownRight size={14} />
                          )}
                          {brl(numero(linha.valor))}
                        </span>
                      </td>

                      <td className="px-4 py-3">
                        <Selo status={linha.status} texto={rotulo(linha.status)} />
                      </td>

                      <td className="px-4 py-3 text-zinc-400">
                        {linha.conciliado ? "sim" : "—"}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>

            {meta && meta.total_pages > 1 && (
              <div className="flex items-center justify-between gap-4 p-4 border-t border-zinc-800 text-sm">
                <span className="text-zinc-500">
                  Página {meta.page} de {meta.total_pages} · {meta.total} lançamento(s)
                </span>

                <div className="flex gap-2">
                  <button
                    disabled={meta.page <= 1}
                    onClick={() => setFiltros((a) => ({ ...a, page: (a.page ?? 1) - 1 }))}
                    className="px-3 py-1.5 rounded-lg bg-zinc-800 hover:bg-zinc-700 transition disabled:opacity-40"
                  >
                    Anterior
                  </button>

                  <button
                    disabled={meta.page >= meta.total_pages}
                    onClick={() => setFiltros((a) => ({ ...a, page: (a.page ?? 1) + 1 }))}
                    className="px-3 py-1.5 rounded-lg bg-zinc-800 hover:bg-zinc-700 transition disabled:opacity-40"
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
