import { api, gatewayApi } from "./client"

// A diferença de um repasse, decomposta em NÚMERO.
//
// A observação diz o mesmo em prosa e a tela a corta. Quem olha a lista quer
// decidir "eu ajo nisso?", e isso se responde com duas colunas: quanto da
// diferença é nota faltando (providência: trazer a nota) e quanto sobra sem
// explicação (providência: alguém olhar).
export interface DecomposicaoDaDiferenca {
  sem_nota: string
  vendas_sem_nota: number
  sem_titulo: string
  notas_sem_titulo: number
  ajustes: string
  notas_rateadas: number
  residuo: string
  // O custo do parcelamento no relatório do marketplace. INFORMAÇÃO, não exclusão:
  // em parte das vendas ele é somado ao bruto e a nota não o documenta; em outras
  // é custo do vendedor, subtraído do bruto como a comissão, e ali a nota vale o
  // bruto inteiro. O relatório não distingue os dois casos, então ele continua
  // entrando como causa da diferença e não sai da base de comparação.
  parcelamento: string
}

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
  // Vem nula enquanto o repasse não foi comparado com o OMIE.
  decomposicao: DecomposicaoDaDiferenca | null
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
  // Os repasses que couberam na JANELA desta execução — não o total.
  repasses: number
  // Quantos existem ao todo. Sem os dois números, "0 de 13" lia como resultado final
  // quando era recorte de 30 dias sobre 35 repasses.
  repasses_no_total?: number
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
  // Recorte pela data de PAGAMENTO do repasse — a mesma por que a lista é ordenada.
  // Filtrava pela data de conferência, que é recarimbada a cada execução e por isso não
  // selecionava nada: "últimos 7 dias" devolvia os 35, inclusive os de julho.
  start_date?: string
  end_date?: string
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

// As vendas que compõem um repasse.
//
// A tela mostrava "268 venda(s)" e o porquê da diferença ficava numa tarefa de
// terminal. É abrindo a lista que se vê que a diferença inteira são as vendas
// sem NF, e não dinheiro faltando.
export interface VendaDoRepasse {
  id: number
  pedido: string | null
  liberado_em: string | null
  valor: string | null
  nf: string | null
  serie: string | null
  valor_nf: string | null
  canal: string | null
  // Nota de pacote vale por várias vendas: sem dizer isso, a linha parece ter
  // NF maior que a venda.
  pacote: boolean
}

export interface VendasDoRepasse {
  total: number
  exibidas: number
  totais: {
    vendas: string
    notas: string
    sem_nota: number
    valor_sem_nota: string
  }
  items: VendaDoRepasse[]
}

export async function fetchVendasDoRepasse(repasseId: number): Promise<VendasDoRepasse> {
  const { data } = await api.get<VendasDoRepasse>(
    `/conciliacoes/repasses/${repasseId}/vendas`,
  )

  return data
}
