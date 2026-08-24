import {
  LayoutDashboard,
  ArrowLeftRight,
  AlertTriangle,
  Plug,
  Scale,
  Undo2,
  ArrowRightLeft,
  KeyRound,
  Users,
  LogOut,
} from "lucide-react"

import { Link, useLocation, useNavigate } from "react-router-dom"
import { useState } from "react"

import { logout } from "../../api/auth"
import { useAuth } from "../../store/useAuth"

export default function Sidebar() {
  const location = useLocation()
  const navigate = useNavigate()

  const user = useAuth((state) => state.user)
  const tenants = useAuth((state) => state.tenants)
  const currentTenantId = useAuth((state) => state.currentTenantId)
  const setTenant = useAuth((state) => state.setTenant)

  const [signingOut, setSigningOut] = useState(false)

  const currentTenant = tenants.find((t) => t.id === currentTenantId)

  async function handleLogout() {
    setSigningOut(true)

    await logout()

    navigate("/login", { replace: true })
  }

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
      label: "Conta virtual",
      icon: Scale,
      path: "/saldos",
    },
    {
      label: "Divergências",
      icon: AlertTriangle,
      path: "/divergencias",
    },
    {
      label: "Movimentações",
      icon: ArrowRightLeft,
      path: "/movimentacoes",
    },
    {
      label: "Devoluções",
      icon: Undo2,
      path: "/devolucoes",
    },
    {
      label: "Integrações",
      icon: Plug,
      path: "/integracoes",
    },
    {
      label: "Equipe",
      icon: Users,
      path: "/equipe",
    },
    {
      label: "Configurações",
      icon: KeyRound,
      path: "/configuracoes",
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
            Organização
          </p>

          {/* Com mais de uma empresa isto precisa ser TROCÁVEL. Cada empresa
              tem as próprias chaves de API, contas e lançamentos; sem seletor,
              quem pertence a duas fica preso na primeira e lê a tela vazia da
              outra como se os dados tivessem sumido. */}
          {tenants.length > 1 ? (
            <select
              value={currentTenantId ?? ""}
              onChange={(e) => setTenant(Number(e.target.value))}
              className="w-full mt-3 bg-zinc-900 border border-zinc-700 hover:border-zinc-500 rounded-2xl px-3 py-2.5 text-sm text-white transition cursor-pointer"
              aria-label="Trocar de organização"
            >
              {tenants.map((tenant) => (
                <option key={tenant.id} value={tenant.id}>
                  {tenant.name}
                </option>
              ))}
            </select>
          ) : (
            <h3 className="text-white font-medium truncate mt-3">
              {currentTenant?.name ?? "—"}
            </h3>
          )}

          <div className="flex items-center justify-between mt-2 gap-3">
            <p className="text-sm text-zinc-400 truncate min-w-0">
              {user?.email ?? ""}
              {currentTenant ? ` · ${currentTenant.role}` : ""}
            </p>

            <div className="w-3 h-3 rounded-full bg-emerald-400 animate-pulse shrink-0" />
          </div>
        </div>

        <button
          onClick={handleLogout}
          disabled={signingOut}
          className="w-full flex items-center gap-3 px-4 py-3 rounded-2xl text-zinc-400 hover:bg-red-500/10 hover:text-red-400 transition-all duration-200 disabled:opacity-50"
        >
          <LogOut size={18} />

          <span className="font-medium">
            {signingOut ? "Saindo..." : "Sair"}
          </span>
        </button>
      </div>
    </aside>
  )
}