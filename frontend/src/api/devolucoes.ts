import { api } from "./client"

export type StatusDevolucao =
  | "aberta"
  | "com_origem"
  | "aguardando_nota"
  | "concluida"
  | "sem_origem"

export interface NotaDaDevolucao {
  id: number
  numero: string
  emitida_em: string | null
  valor: string | null
  chave: string | null
}

export interface Devolucao {
  id: number
  external_id: string
  tipo: "devolucao" | "disputa" | "chargeback"
  status: StatusDevolucao
  plataforma: string | null
  valor: string
  aberta_em: string | null
  concluida_em: string | null
  pedido: { id: number; external_id: string } | null
  nota_de_venda: NotaDaDevolucao | null
  nota_de_devolucao: NotaDaDevolucao | null
  pendencia: string | null
}

export interface DevolucoesResponse {
  items: Devolucao[]
  meta: { page: number; per_page: number; total: number; total_pages: number }
  resumo: {
    total: number
    em_aberto: number
    por_status: Record<string, number>
  }
}

export async function fetchDevolucoes(
  status?: StatusDevolucao | "",
): Promise<DevolucoesResponse> {
  const { data } = await api.get<DevolucoesResponse>("/devolucoes", {
    params: status ? { status } : {},
  })

  return data
}

export async function rastrearDevolucoes(): Promise<{ resumo: Record<string, number> }> {
  const { data } = await api.post("/devolucoes/rastrear", {})

  return data
}
