import { useState } from "react"
import {
  AlertTriangle,
  Search,
  Filter,
  MessageSquareWarning,
  CheckCircle2,
  Clock,
  ChevronDown,
} from "lucide-react"

const stats = [
  {
    title: "Divergências abertas",
    value: "17",
    change: "+4 hoje",
    tone: "text-red-400",
  },
  {
    title: "Em contestação",
    value: "6",
    change: "aguardando marketplace",
    tone: "text-yellow-400",
  },
  {
    title: "Resolvidas no mês",
    value: "42",
    change: "+9 vs. mês anterior",
    tone: "text-emerald-400",
  },
  {
    title: "Valor total em disputa",
    value: "R$ 4.812,90",
    change: "17 pedidos",
    tone: "text-white",
  },
]

const divergences = [
  {
    id: "DIV-1042",
    status: "Aberta",
    pedido: "#SP-11382",
    nf: "NF-10030",
    plataforma: "Shopee",
    tipo: "Valor a menor",
    esperado: "R$ 820,00",
    recebido: "R$ 793,20",
    diferenca: "-R$ 26,80",
    data: "09/05/2026",
  },
  {
    id: "DIV-1041",
    status: "Em contestação",
    pedido: "#ML-90350",
    nf: "NF-10041",
    plataforma: "Mercado Livre",
    tipo: "Taxa divergente",
    esperado: "R$ 1.560,00",
    recebido: "R$ 1.498,40",
    diferenca: "-R$ 61,60",
    data: "08/05/2026",
  },
  {
    id: "DIV-1039",
    status: "Aberta",
    pedido: "#AM-88311",
    nf: "NF-10031",
    plataforma: "Amazon",
    tipo: "Não recebido",
    esperado: "R$ 2.390,00",
    recebido: "R$ 0,00",
    diferenca: "-R$ 2.390,00",
    data: "07/05/2026",
  },
  {
    id: "DIV-1035",
    status: "Resolvida",
    pedido: "#MG-66192",
    nf: "NF-10032",
    plataforma: "Magalu",
    tipo: "Repasse duplicado",
    esperado: "R$ 530,00",
    recebido: "R$ 1.060,00",
    diferenca: "+R$ 530,00",
    data: "05/05/2026",
  },
  {
    id: "DIV-1031",
    status: "Em contestação",
    pedido: "#SP-11290",
    nf: "NF-10022",
    plataforma: "Shopee",
    tipo: "Frete cobrado a mais",
    esperado: "R$ 940,00",
    recebido: "R$ 887,50",
    diferenca: "-R$ 52,50",
    data: "04/05/2026",
  },
]

const statusStyle: Record<string, string> = {
  Aberta: "bg-red-500/15 text-red-400 border border-red-500/20",
  "Em contestação":
    "bg-yellow-500/15 text-yellow-400 border border-yellow-500/20",
  Resolvida: "bg-emerald-500/15 text-emerald-400 border border-emerald-500/20",
}

const statusIcon: Record<string, any> = {
  Aberta: AlertTriangle,
  "Em contestação": Clock,
  Resolvida: CheckCircle2,
}

export default function Divergences() {
  const [statusFilter, setStatusFilter] = useState("Todos")

  const filtered =
    statusFilter === "Todos"
      ? divergences
      : divergences.filter((d) => d.status === statusFilter)

  return (
    <div className="space-y-6">
      <div className="flex flex-col lg:flex-row lg:items-center lg:justify-between gap-4">
        <div>
          <p className="text-zinc-400 text-sm">Conciliação Financeira</p>
          <h1 className="text-3xl font-bold tracking-tight mt-1">
            Divergências
          </h1>
        </div>

        <div className="flex flex-wrap gap-3">
          <select className="bg-zinc-900 border border-zinc-800 rounded-xl px-4 py-3 text-sm outline-none focus:border-zinc-600">
            <option>Últimos 30 dias</option>
            <option>Últimos 7 dias</option>
            <option>Hoje</option>
          </select>

          <button className="bg-white text-black font-medium px-5 py-3 rounded-xl hover:opacity-90 transition">
            Reprocessar divergências
          </button>
        </div>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-4 gap-4">
        {stats.map((item) => (
          <div
            key={item.title}
            className="bg-zinc-900 border border-zinc-800 rounded-3xl p-5 shadow-xl"
          >
            <p className="text-sm text-zinc-400">{item.title}</p>
            <h2 className={`text-2xl font-bold mt-3 ${item.tone}`}>
              {item.value}
            </h2>
            <p className="text-xs text-zinc-500 mt-2">{item.change}</p>
          </div>
        ))}
      </div>

      <div className="bg-zinc-900 border border-zinc-800 rounded-3xl overflow-hidden shadow-2xl">
        <div className="flex flex-col lg:flex-row lg:items-center lg:justify-between gap-4 p-5 border-b border-zinc-800">
          <div>
            <h2 className="text-lg font-semibold">Casos de divergência</h2>
            <p className="text-zinc-400 text-sm mt-1">
              Diferenças entre o esperado (OMIE) e o recebido do marketplace.
            </p>
          </div>

          <div className="flex flex-wrap gap-3">
            <div className="relative">
              <Search
                size={16}
                className="absolute left-4 top-1/2 -translate-y-1/2 text-zinc-500"
              />
              <input
                placeholder="Buscar pedido, NF ou plataforma"
                className="bg-zinc-950 border border-zinc-800 rounded-xl pl-10 pr-4 py-3 text-sm min-w-[260px] outline-none focus:border-zinc-600"
              />
            </div>

            <div className="relative">
              <select
                value={statusFilter}
                onChange={(e) => setStatusFilter(e.target.value)}
                className="appearance-none bg-zinc-950 border border-zinc-800 rounded-xl pl-4 pr-9 py-3 text-sm outline-none focus:border-zinc-600"
              >
                <option>Todos</option>
                <option>Aberta</option>
                <option>Em contestação</option>
                <option>Resolvida</option>
              </select>
              <ChevronDown
                size={15}
                className="absolute right-3 top-1/2 -translate-y-1/2 text-zinc-500 pointer-events-none"
              />
            </div>

            <button className="flex items-center gap-2 bg-zinc-950 border border-zinc-800 rounded-xl px-4 py-3 text-sm hover:border-zinc-600 transition">
              <Filter size={15} />
              Filtros
            </button>
          </div>
        </div>

        <div className="overflow-x-auto">
          <table className="w-full min-w-[1200px]">
            <thead className="bg-zinc-950/80 text-zinc-400 text-sm">
              <tr>
                <th className="text-left font-medium px-6 py-4">Caso</th>
                <th className="text-left font-medium px-6 py-4">Status</th>
                <th className="text-left font-medium px-6 py-4">Pedido</th>
                <th className="text-left font-medium px-6 py-4">NF</th>
                <th className="text-left font-medium px-6 py-4">
                  Plataforma
                </th>
                <th className="text-left font-medium px-6 py-4">Tipo</th>
                <th className="text-left font-medium px-6 py-4">
                  Valor Esperado
                </th>
                <th className="text-left font-medium px-6 py-4">
                  Valor Recebido
                </th>
                <th className="text-left font-medium px-6 py-4">
                  Diferença
                </th>
                <th className="text-left font-medium px-6 py-4">Data</th>
                <th className="text-left font-medium px-6 py-4">Ações</th>
              </tr>
            </thead>

            <tbody>
              {filtered.map((row) => {
                const Icon = statusIcon[row.status]
                const isPositive = row.diferenca.startsWith("+")

                return (
                  <tr
                    key={row.id}
                    className="border-t border-zinc-800 hover:bg-zinc-800/30 transition"
                  >
                    <td className="px-6 py-5 text-zinc-400">{row.id}</td>

                    <td className="px-6 py-5">
                      <span
                        className={`inline-flex items-center gap-1.5 px-3 py-1 rounded-full text-xs font-medium ${statusStyle[row.status]}`}
                      >
                        <Icon size={13} />
                        {row.status}
                      </span>
                    </td>

                    <td className="px-6 py-5 font-medium">{row.pedido}</td>
                    <td className="px-6 py-5 text-zinc-300">{row.nf}</td>
                    <td className="px-6 py-5 text-zinc-300">
                      {row.plataforma}
                    </td>
                    <td className="px-6 py-5 text-zinc-300">{row.tipo}</td>
                    <td className="px-6 py-5">{row.esperado}</td>
                    <td className="px-6 py-5">{row.recebido}</td>
                    <td
                      className={`px-6 py-5 font-medium ${isPositive ? "text-emerald-400" : "text-red-400"}`}
                    >
                      {row.diferenca}
                    </td>
                    <td className="px-6 py-5 text-zinc-400">{row.data}</td>

                    <td className="px-6 py-5">
                      <div className="flex gap-2">
                        <button className="bg-zinc-800 hover:bg-zinc-700 transition px-3 py-2 rounded-lg text-sm">
                          Detalhes
                        </button>

                        {row.status !== "Resolvida" && (
                          <button className="flex items-center gap-1.5 bg-white text-black hover:opacity-90 transition px-3 py-2 rounded-lg text-sm font-medium">
                            <MessageSquareWarning size={14} />
                            Contestar
                          </button>
                        )}
                      </div>
                    </td>
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  )
}