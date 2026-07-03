import { useState } from "react"
import {
  Plug,
  CheckCircle2,
  XCircle,
  RefreshCw,
  Settings,
  Plus,
  ShoppingBag,
  Building2,
  Wallet,
} from "lucide-react"

const integrations = [
  {
    id: "int-1",
    nome: "Mercado Livre",
    categoria: "Marketplace",
    icon: ShoppingBag,
    status: "Conectado",
    ultimaSync: "há 2 min",
    contaLigada: "loja.principal@mercadolivre",
    color: "from-yellow-400 to-yellow-600",
  },
  {
    id: "int-2",
    nome: "Shopee",
    categoria: "Marketplace",
    icon: ShoppingBag,
    status: "Conectado",
    ultimaSync: "há 6 min",
    contaLigada: "shop-oficial-92",
    color: "from-orange-400 to-orange-600",
  },
  {
    id: "int-3",
    nome: "Amazon",
    categoria: "Marketplace",
    icon: ShoppingBag,
    status: "Erro de autenticação",
    ultimaSync: "há 3 horas",
    contaLigada: "seller-central-br",
    color: "from-zinc-400 to-zinc-600",
  },
  {
    id: "int-4",
    nome: "Magalu",
    categoria: "Marketplace",
    icon: ShoppingBag,
    status: "Conectado",
    ultimaSync: "há 14 min",
    contaLigada: "magalu-parceiro-04",
    color: "from-blue-400 to-blue-600",
  },
  {
    id: "int-5",
    nome: "OMIE",
    categoria: "ERP",
    icon: Building2,
    status: "Conectado",
    ultimaSync: "há 1 min",
    contaLigada: "empresa-matriz",
    color: "from-indigo-400 to-indigo-600",
  },
  {
    id: "int-6",
    nome: "InfinitePay",
    categoria: "Gateway de pagamento",
    icon: Wallet,
    status: "Pausado",
    ultimaSync: "há 1 dia",
    contaLigada: "pay.zfxsoftware",
    color: "from-emerald-400 to-emerald-600",
  },
]

const statusStyle: Record<string, string> = {
  Conectado: "bg-emerald-500/15 text-emerald-400 border border-emerald-500/20",
  "Erro de autenticação":
    "bg-red-500/15 text-red-400 border border-red-500/20",
  Pausado: "bg-yellow-500/15 text-yellow-400 border border-yellow-500/20",
}

const statusIcon: Record<string, any> = {
  Conectado: CheckCircle2,
  "Erro de autenticação": XCircle,
  Pausado: RefreshCw,
}

export default function Integrations() {
  const [categoryFilter, setCategoryFilter] = useState("Todas")

  const categories = ["Todas", "Marketplace", "ERP", "Gateway de pagamento"]

  const filtered =
    categoryFilter === "Todas"
      ? integrations
      : integrations.filter((i) => i.categoria === categoryFilter)

  const connectedCount = integrations.filter(
    (i) => i.status === "Conectado",
  ).length

  return (
    <div className="space-y-6">
      <div className="flex flex-col lg:flex-row lg:items-center lg:justify-between gap-4">
        <div>
          <p className="text-zinc-400 text-sm">Conciliação Financeira</p>
          <h1 className="text-3xl font-bold tracking-tight mt-1">
            Integrações
          </h1>
        </div>

        <div className="flex flex-wrap gap-3">
          {categories.map((cat) => (
            <button
              key={cat}
              onClick={() => setCategoryFilter(cat)}
              className={`px-4 py-3 rounded-xl text-sm font-medium transition border ${
                categoryFilter === cat
                  ? "bg-white text-black border-white"
                  : "bg-zinc-900 text-zinc-300 border-zinc-800 hover:border-zinc-600"
              }`}
            >
              {cat}
            </button>
          ))}

          <button className="flex items-center gap-2 bg-white text-black font-medium px-5 py-3 rounded-xl hover:opacity-90 transition">
            <Plus size={16} />
            Nova integração
          </button>
        </div>
      </div>

      <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
        <div className="bg-zinc-900 border border-zinc-800 rounded-3xl p-5 shadow-xl">
          <p className="text-sm text-zinc-400">Integrações conectadas</p>
          <h2 className="text-2xl font-bold mt-3 text-emerald-400">
            {connectedCount} / {integrations.length}
          </h2>
        </div>

        <div className="bg-zinc-900 border border-zinc-800 rounded-3xl p-5 shadow-xl">
          <p className="text-sm text-zinc-400">Sincronizações hoje</p>
          <h2 className="text-2xl font-bold mt-3">312</h2>
        </div>

        <div className="bg-zinc-900 border border-zinc-800 rounded-3xl p-5 shadow-xl">
          <p className="text-sm text-zinc-400">Precisam de atenção</p>
          <h2 className="text-2xl font-bold mt-3 text-red-400">
            {
              integrations.filter((i) => i.status !== "Conectado")
                .length
            }
          </h2>
        </div>
      </div>

      <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
        {filtered.map((item) => {
          const Icon = item.icon
          const StatusIcon = statusIcon[item.status]

          return (
            <div
              key={item.id}
              className="bg-zinc-900 border border-zinc-800 rounded-3xl p-6 shadow-xl"
            >
              <div className="flex items-start justify-between">
                <div className="flex items-center gap-4">
                  <div
                    className={`w-12 h-12 rounded-2xl bg-gradient-to-br ${item.color} flex items-center justify-center text-white shadow-lg`}
                  >
                    <Icon size={20} />
                  </div>

                  <div>
                    <h3 className="font-semibold text-lg">{item.nome}</h3>
                    <p className="text-sm text-zinc-400 mt-0.5">
                      {item.categoria}
                    </p>
                  </div>
                </div>

                <span
                  className={`inline-flex items-center gap-1.5 px-3 py-1 rounded-full text-xs font-medium ${statusStyle[item.status]}`}
                >
                  <StatusIcon size={13} />
                  {item.status}
                </span>
              </div>

              <div className="mt-6 space-y-3 border-t border-zinc-800 pt-5">
                <div className="flex items-center justify-between text-sm">
                  <span className="text-zinc-400">Conta vinculada</span>
                  <span className="font-medium">{item.contaLigada}</span>
                </div>

                <div className="flex items-center justify-between text-sm">
                  <span className="text-zinc-400">Última sincronização</span>
                  <span className="font-medium">{item.ultimaSync}</span>
                </div>
              </div>

              <div className="mt-6 flex gap-2">
                <button className="flex-1 flex items-center justify-center gap-2 bg-zinc-800 hover:bg-zinc-700 transition px-4 py-3 rounded-xl text-sm font-medium">
                  <RefreshCw size={15} />
                  Sincronizar agora
                </button>

                <button className="flex items-center justify-center gap-2 bg-zinc-800 hover:bg-zinc-700 transition px-4 py-3 rounded-xl text-sm font-medium">
                  <Settings size={15} />
                </button>
              </div>
            </div>
          )
        })}
      </div>

      <div className="bg-zinc-900 border border-zinc-800 rounded-3xl p-6 flex flex-col lg:flex-row lg:items-center lg:justify-between gap-4">
        <div className="flex items-center gap-4">
          <div className="w-12 h-12 rounded-2xl bg-white/5 border border-white/10 flex items-center justify-center text-zinc-300">
            <Plug size={20} />
          </div>

          <div>
            <h3 className="font-semibold">Conectar nova plataforma</h3>
            <p className="text-sm text-zinc-400 mt-1">
              Adicione marketplaces, ERPs ou gateways de pagamento à
              conciliação.
            </p>
          </div>
        </div>

        <button className="flex items-center gap-2 bg-white text-black font-medium px-5 py-3 rounded-xl hover:opacity-90 transition">
          <Plus size={16} />
          Adicionar integração
        </button>
      </div>
    </div>
  )
}