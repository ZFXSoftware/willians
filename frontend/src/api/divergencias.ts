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
  pedido: string | null
  nota_fiscal: string | null
  contestacao: {
    protocolo?: string
    observacao?: string
    aberta_em?: string
    por?: string
  } | null
  metadata: Record<string, unknown>
}

export interface CampoContestacao {
  rotulo: string
  valor: string
}

export interface Contestacao {
  url: string
  /** O caminho da central muda e não é documentado: o link é sugerido, não garantido. */
  url_confirmada: boolean
  plataforma: string | null
  assunto: string
  texto: string
  campos: CampoContestacao[]
}

export interface ResumoDivergencias {
  por_status: Record<string, number>
  por_tipo: Record<string, number>
  // Só o que foi de fato comparado: "título não encontrado" não é disputa.
  valor_em_disputa: string
  sem_comparacao: number
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

export async function fetchContestacao(id: number): Promise<Contestacao> {
  const { data } = await api.get<Contestacao>(`/divergencias/${id}/contestacao`)

  return data
}

export async function contestar(
  id: number,
  dados: { protocolo?: string; observacao?: string },
): Promise<Divergencia> {
  const { data } = await api.post<Divergencia>(`/divergencias/${id}/contestar`, dados)

  return data
}

export async function resolverDivergencia(
  id: number,
  observacao?: string,
): Promise<Divergencia> {
  const { data } = await api.post<Divergencia>(`/divergencias/${id}/resolver`, { observacao })

  return data
}
