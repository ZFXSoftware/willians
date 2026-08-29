import { api } from "./client"

// O razão inteiro, navegável. O painel mostra só as últimas movimentações — e
// com milhares de lançamentos isso não responde "e os outros?".
export interface Lancamento {
  id: number
  data: string
  tipo: string
  direcao: "credit" | "debit"
  valor: string
  status: string
  plataforma: string | null
  /** O que a pessoa reconhece: o número do pedido no marketplace. */
  pedido: string | null
  /** Id do pagamento no Mercado Pago, quando não há pedido. */
  pagamento: string | null
  /** Nosso identificador interno. Serve para suporte, não para leitura. */
  referencia: string
  conciliado: boolean
}

export interface ResumoLancamentos {
  total: number
  por_tipo: Record<string, number>
  creditos: string
  debitos: string
}

export interface LancamentosResponse {
  items: Lancamento[]
  meta: { page: number; per_page: number; total: number; total_pages: number }
  resumo: ResumoLancamentos
}

export interface FiltrosLancamentos {
  tipo?: string
  status?: string
  plataforma?: string
  busca?: string
  start_date?: string
  end_date?: string
  page?: number
  per_page?: number
}

export async function fetchLancamentos(
  filtros: FiltrosLancamentos = {},
): Promise<LancamentosResponse> {
  const { data } = await api.get<LancamentosResponse>("/lancamentos", {
    params: filtros,
  })

  return data
}
