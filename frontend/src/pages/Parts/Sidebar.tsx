import {
  LayoutDashboard,
  ArrowLeftRight,
  AlertTriangle,
  Plug,
  LogOut,
} from "lucide-react"

import { Link, useLocation } from "react-router-dom"

export default function Sidebar() {
  const location = useLocation()

  const items = [
    {
      label: "Dashboard",
      icon: LayoutDashboard,
      path: "/",
    },
    {
      label: "Conciliação",
      icon: ArrowLeftRight,
      path: "/conciliation",
    },
    {
      label: "Divergências",
      icon: AlertTriangle,
      path: "/divergencias",
    },
    {
      label: "Integrações",
      icon: Plug,
      path: "/integracoes",
    },
  ]

  return (
    <aside className="w-[280px] min-h-screen bg-[#0b1120] border-r border-white/5 px-5 py-6 hidden lg:flex flex-col sticky top-0 shadow-2xl">
      {/* Logo */}
      <div className="px-2">
        <div className="flex items-center gap-4">
          <div className="w-12 h-12 rounded-2xl bg-gradient-to-br from-indigo-500 to-violet-600 flex items-center justify-center text-white font-bold text-xl shadow-lg shadow-indigo-500/20">
          </div>

          <div>
            <h1 className="text-xl font-semibold tracking-tight text-white">
              Willians
            </h1>

            <p className="text-sm text-zinc-400 mt-1">
              Financial Reconciliation
            </p>
          </div>
        </div>
      </div>

      {/* Navigation */}
      <nav className="mt-12 flex-1">
        <p className="text-xs uppercase tracking-[0.2em] text-zinc-500 px-4 mb-4">
          Navegação
        </p>

        <div className="space-y-2">
          {items.map((item) => {
            const Icon = item.icon
            const isActive = location.pathname === item.path

            return (
              <Link
                key={item.label}
                to={item.path}
                className={`group flex items-center gap-4 px-4 py-3 rounded-2xl transition-all duration-200 ${
                  isActive
                    ? "bg-white text-black shadow-lg"
                    : "text-zinc-400 hover:bg-white/5 hover:text-white"
                }`}
              >
                <div
                  className={`transition ${
                    isActive
                      ? "text-black"
                      : "text-zinc-500 group-hover:text-white"
                  }`}
                >
                  <Icon size={19} strokeWidth={2.2} />
                </div>

                <span className="font-medium text-[15px]">
                  {item.label}
                </span>
              </Link>
            )
          })}
        </div>
      </nav>

      {/* Bottom */}
      <div className="pt-6 border-t border-white/5">
        <div className="bg-white/5 border border-white/5 rounded-3xl p-4 mb-4">
          <p className="text-xs uppercase tracking-wider text-zinc-500">
            Ambiente
          </p>

          <div className="flex items-center justify-between mt-3">
            <div>
              <h3 className="text-white font-medium">
                Produção
              </h3>

              <p className="text-sm text-zinc-400 mt-1">
                Sincronização ativa
              </p>
            </div>

            <div className="w-3 h-3 rounded-full bg-emerald-400 animate-pulse" />
          </div>
        </div>

        <button className="w-full flex items-center gap-3 px-4 py-3 rounded-2xl text-zinc-400 hover:bg-red-500/10 hover:text-red-400 transition-all duration-200">
          <LogOut size={18} />

          <span className="font-medium">
            Sair
          </span>
        </button>
      </div>
    </aside>
  )
}