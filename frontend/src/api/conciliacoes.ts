import { api, gatewayApi } from "./client"

export interface Registro {
  id: number
  status: string
  match_type: string | null
  confianca: string
  referencia: string | null
  plataforma: string | null
  valor_recebido: string | null
  valor_esperado: string | null
  diferenca: string | null
  data: string | null
  observacao: string | null
  payout_batch_id: number | null
  financial_entry_id: number | null
}

export interface Meta {
  page: number
  per_page: number
  total: number
  total_pages: number
}

export interface ResumoConciliacao {
  por_status: Record<string, number>
  total_conciliado: string
  divergencias_abertas: number
  ultima_execucao: string | null
  execucoes_hoje: number
  execucao: ExecucaoConciliacao | null
}

// O desfecho da última execução. A conciliação roda em fila: a tela dispara e
// recebe "enfileirado", nada mais — sem isto o resultado só existia no log.
export interface ExecucaoConciliacao {
  status: string
  iniciada_em: string | null
  terminada_em: string | null
  repasses: number
  conferidos: number
  divergentes: number
  // Estes três separam as causas de "não conferiu": sem título no OMIE é um
  // problema, sem nota fiscal nossa é outro, e ter os dois e não casar é o
  // terceiro.
  titulos_no_omie: number | null
  repasses_com_nf: number | null
  sem_titulo: number | null
  periodo: string
  erro: string | null
}

export interface RegistrosResponse {
  items: Registro[]
  meta: Meta
  resumo: ResumoConciliacao
}

export interface FiltrosRegistros {
  status?: string
  plataforma?: string
  busca?: string
  start_date?: string
  page?: number
  per_page?: number
}

export async function fetchRegistros(
  filtros: FiltrosRegistros = {},
): Promise<RegistrosResponse> {
  const { data } = await api.get<RegistrosResponse>("/conciliacoes/registros", {
    params: filtros,
  })

  return data
}

// O disparo passa pelo gateway, que enfileira o processamento.
export async function processarConciliacao(): Promise<{ job_id: string }> {
  const { data } = await gatewayApi.post("/conciliacoes/processar", {})

  return data
}
