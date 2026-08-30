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
  // Quantas vendas o repasse carrega dentro. Doze linhas para milhares de
  // lançamentos parece que quase nada é conferido — e é o contrário: cada
  // repasse junta uma centena de vendas.
  vendas: number | null
  pago_em: string | null
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
  // Enquanto houver notas na fila para o OMIE, TODO número desta tela é
  // provisório: o repasse comparado hoje contra 3 títulos será comparado
  // amanhã contra 87.
  notas_a_enviar: number
  // Notas que NUNCA vão virar título: emitidas sem valor, que o OMIE recusa.
  // Não são espera — são uma correção pendente no Tiny, e o repasse que
  // contiver uma delas é comparado sem ela, com a diferença explicada.
  notas_recusadas: number
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
//
// O período importa mais do que parece: sem ele o backend concilia os ÚLTIMOS
// 30 DIAS de repasses, e repasse mais antigo que isso nunca vira registro — não
// é a listagem que esconde, é que ele nunca foi conferido. Era por isso que a
// tela mostrava doze linhas e nenhuma paginação.
export async function processarConciliacao(
  periodo?: { start_date: string; end_date: string },
): Promise<{ job_id: string }> {
  const { data } = await gatewayApi.post("/conciliacoes/processar", periodo ?? {})

  return data
}

// Quanto tempo para trás conciliar. O padrão do backend é 30 dias.
export const PERIODOS = [
  { valor: 30, rotulo: "Últimos 30 dias" },
  { valor: 90, rotulo: "Últimos 3 meses" },
  { valor: 180, rotulo: "Últimos 6 meses" },
  { valor: 365, rotulo: "Último ano" },
] as const

export function janelaDe(dias: number): { start_date: string; end_date: string } {
  const fim = new Date()
  const inicio = new Date(fim.getTime() - dias * 24 * 60 * 60 * 1000)

  return {
    start_date: inicio.toISOString().slice(0, 10),
    end_date: fim.toISOString().slice(0, 10),
  }
}
