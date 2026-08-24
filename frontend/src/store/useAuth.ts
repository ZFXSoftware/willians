import { create } from "zustand"

export interface AuthUser {
  id: number
  name: string
  email: string
  status: string
}

export interface AuthTenant {
  id: number
  name: string
  role: string
}

export interface SessionPayload {
  token: string
  expires_at?: string
  user: AuthUser
  tenants: AuthTenant[]
}

interface AuthState {
  token: string | null
  user: AuthUser | null
  tenants: AuthTenant[]
  currentTenantId: number | null

  setSession: (payload: SessionPayload) => void
  setProfile: (user: AuthUser, tenants: AuthTenant[]) => void
  setTenant: (tenantId: number) => void
  clear: () => void
}

const TOKEN_KEY = "willians.token"
const TENANT_KEY = "willians.tenant"

function readStoredTenant(): number | null {
  const raw = localStorage.getItem(TENANT_KEY)
  return raw ? Number(raw) : null
}

// Só o token e o tenant escolhido são persistidos; o perfil é recarregado do
// /auth/me a cada boot, então um usuário desativado no servidor não continua
// "logado" com dados velhos do localStorage.
export const useAuth = create<AuthState>((set) => ({
  token: localStorage.getItem(TOKEN_KEY),
  user: null,
  tenants: [],
  currentTenantId: readStoredTenant(),

  setSession: ({ token, user, tenants }) => {
    localStorage.setItem(TOKEN_KEY, token)

    // Respeita a empresa escolhida da última vez, quando ela ainda vale.
    // Antes o login sempre caía em tenants[0], então quem pertence a mais de
    // uma empresa voltava para a primeira a cada entrada — e via a tela vazia
    // achando que os dados tinham sumido.
    const guardado = readStoredTenant()

    const tenantId =
      tenants.find((t) => t.id === guardado)?.id ?? (tenants.length > 0 ? tenants[0].id : null)

    if (tenantId) localStorage.setItem(TENANT_KEY, String(tenantId))

    set({ token, user, tenants, currentTenantId: tenantId })
  },

  setProfile: (user, tenants) =>
    set((state) => {
      const stillValid = tenants.some((t) => t.id === state.currentTenantId)

      const tenantId = stillValid
        ? state.currentTenantId
        : tenants.length > 0
          ? tenants[0].id
          : null

      if (tenantId) localStorage.setItem(TENANT_KEY, String(tenantId))

      return { user, tenants, currentTenantId: tenantId }
    }),

  setTenant: (tenantId) => {
    localStorage.setItem(TENANT_KEY, String(tenantId))
    set({ currentTenantId: tenantId })
  },

  clear: () => {
    localStorage.removeItem(TOKEN_KEY)
    localStorage.removeItem(TENANT_KEY)
    set({ token: null, user: null, tenants: [], currentTenantId: null })
  },
}))
