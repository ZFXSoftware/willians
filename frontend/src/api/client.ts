import axios from "axios"
import type { AxiosInstance } from "axios"
import { useAuth } from "../store/useAuth"

// Em desenvolvimento, Rails e gateway ficam em portas diferentes (ver
// docker-compose). Em produção tudo sai da MESMA origem, e o nginx encaminha
// /api e /gateway — por isso o padrão muda com o tipo de build.
//
// O padrão de produção precisa ser relativo, e não localhost: um build com a
// variável vazia embutiria localhost na SPA, e o navegador do usuário tentaria
// chamar a máquina dele. Foi o que aconteceu no primeiro deploy — string vazia
// é falsy, então `|| "http://localhost:3053"` venceu.
const API_URL =
  import.meta.env.VITE_API_URL || (import.meta.env.PROD ? "/api" : "http://localhost:3053")

const GATEWAY_URL =
  import.meta.env.VITE_GATEWAY_URL || (import.meta.env.PROD ? "/gateway" : "http://localhost:3051")

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
