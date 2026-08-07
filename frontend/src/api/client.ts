import axios from "axios"
import type { AxiosInstance } from "axios"
import { useAuth } from "../store/useAuth"

// Rails (autenticação, dados) e gateway (disparo da conciliação) ficam em
// portas diferentes — ver docker-compose.
const API_URL = import.meta.env.VITE_API_URL ?? "http://localhost:3053"
const GATEWAY_URL = import.meta.env.VITE_GATEWAY_URL ?? "http://localhost:3051"

function withAuth(instance: AxiosInstance): AxiosInstance {
  instance.interceptors.request.use((config) => {
    const { token, currentTenantId } = useAuth.getState()

    if (token) {
      config.headers.Authorization = `Bearer ${token}`
    }

    if (currentTenantId) {
      config.headers["X-Tenant-Id"] = String(currentTenantId)
    }

    return config
  })

  instance.interceptors.response.use(
    (response) => response,
    (error) => {
      // Sessão revogada ou expirada no servidor: derruba o estado local. O 401
      // do próprio login não tem token, então não dispara nada.
      if (error.response?.status === 401 && useAuth.getState().token) {
        useAuth.getState().clear()
      }

      return Promise.reject(error)
    },
  )

  return instance
}

export const api = withAuth(axios.create({ baseURL: API_URL }))

export const gatewayApi = withAuth(axios.create({ baseURL: GATEWAY_URL }))

export function errorMessage(error: any, fallback = "Algo deu errado"): string {
  const data = error?.response?.data

  if (data?.details?.length) return data.details.join(", ")

  return data?.error ?? error?.message ?? fallback
}
