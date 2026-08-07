import { api } from "./client"
import { useAuth } from "../store/useAuth"
import type { AuthTenant, AuthUser, SessionPayload } from "../store/useAuth"

export interface RegisterInput {
  name: string
  email: string
  password: string
  tenant_name?: string
}

export async function register(input: RegisterInput): Promise<SessionPayload> {
  const { data } = await api.post<SessionPayload>("/auth/register", input)

  useAuth.getState().setSession(data)

  return data
}

export async function login(
  email: string,
  password: string,
): Promise<SessionPayload> {
  const { data } = await api.post<SessionPayload>("/auth/login", {
    email,
    password,
  })

  useAuth.getState().setSession(data)

  return data
}

export async function logout(): Promise<void> {
  try {
    await api.delete("/auth/logout")
  } finally {
    // Mesmo se a chamada falhar, a sessão local vai embora.
    useAuth.getState().clear()
  }
}

export interface MeResponse {
  user: AuthUser
  tenants: AuthTenant[]
  current_tenant_id: number | null
}

export async function fetchMe(): Promise<MeResponse> {
  const { data } = await api.get<MeResponse>("/auth/me")

  useAuth.getState().setProfile(data.user, data.tenants)

  return data
}
