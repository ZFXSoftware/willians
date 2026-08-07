import { api } from "./client"
import type { Meta } from "./conciliacoes"

export interface Divergencia {
  id: number
  tipo: string
  status: string
  valor_esperado: string | null
  valor_recebido: string | null
  diferenca: string | null
  data: string
  resolvida_em: string | null
  observacoes: string | null
  referencia: string | null
  plataforma: string | null
  metadata: Record<string, unknown>
}

export interface ResumoDivergencias {
  por_status: Record<string, number>
  por_tipo: Record<string, number>
  valor_em_disputa: string
  resolvidas_no_mes: number
}

export interface DivergenciasResponse {
  items: Divergencia[]
  meta: Meta
  resumo: ResumoDivergencias
}

export interface FiltrosDivergencias {
  status?: string
  tipo?: string
  page?: number
  per_page?: number
}

export async function fetchDivergencias(
  filtros: FiltrosDivergencias = {},
): Promise<DivergenciasResponse> {
  const { data } = await api.get<DivergenciasResponse>("/divergencias", {
    params: filtros,
  })

  return data
}
