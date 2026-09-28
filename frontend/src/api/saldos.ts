import { api } from "./client"

export type SituacaoSaldo = "confere" | "divergente" | "nao_conferido"

export interface LadoDoSaldo {
  disponivel: string | null
  futuro: string | null
  total?: string | null
  bloqueado?: string | null
}

export interface SaldoDaConta {
  platform_account_id: number
  nome: string
  plataforma: string
  conferido_em: string | null
  origem_do_saldo: string | null
  saldo_plataforma: LadoDoSaldo
  saldo_interno: LadoDoSaldo
  diferenca: string | null
  situacao: SituacaoSaldo
  // QUAL par foi comparado: `available`, `future` ou `total`. Com três bases
  // possíveis, uma diferença sem dizer entre o que e o que é adivinhação — e o
  // Mercado Livre só informa `total`, então é nele que a comparação cai.
  base_da_comparacao: string | null
}

export interface SaldosResponse {
  items: SaldoDaConta[]
  resumo: {
    total: number
    confere: number
    divergente: number
    nao_conferido: number
  }
}

// Por que uma conta ficou sem espelho. Cada motivo pede uma providência
// diferente — de "autorize o OAuth" a "não faça nada" —, então a tela precisa
// deles separados, e não de uma frase que oferece todas as hipóteses de uma
// vez. O backend manda `motivo`, nunca o texto cru do erro da plataforma.
export type MotivoSemEspelho =
  | "sem_integracao"
  | "nao_conectada"
  | "token_recusado"
  | "limite_de_requisicoes"
  | "relatorio_em_geracao"
  | "sem_suporte"
  | "sem_dados"
  | "erro"
  | "sem_valor_comparavel"

export interface DetalheConferencia {
  platform_account_id: number
  // O serviço devolve `platform`; só o GET /saldos usa `plataforma`.
  platform: string
  situacao: string
  motivo?: MotivoSemEspelho
  mensagem?: string
  diferenca?: string
}

export interface ConferenciaResponse {
  resumo: Record<string, number>
  detalhes: DetalheConferencia[]
}

// O extrato da conta virtual: movimento por movimento, com o saldo corrente do
// NOSSO razão ao lado do que o marketplace calculou. É a coluna dele que torna o
// extrato útil: onde os dois se separam está o movimento que falta ou que sobra.
export interface LinhaDoExtrato {
  ocorrido_em: string | null
  movimento: string
  referencia: string | null
  pedido: string | null
  lancamentos: number
  valor: string
  saldo_nosso: string
  saldo_deles: string | null
  distancia: string | null
  pendentes: number
}

export interface MovimentoPorTipo {
  movimento: string
  quantidade: number
  credito: string
  debito: string
  resultado: string
  pendentes: number
}

export interface ExtratoResponse {
  conta: { id: number; nome: string; plataforma: string }
  saldo: {
    available_balance: string
    future_balance: string
    blocked_balance: string
    total_balance: string
  }
  por_tipo: MovimentoPorTipo[]
  // A resposta para "como o saldo chegou aqui": a PRIMEIRA linha em que os dois
  // saldos se separaram. Depois dela todas divergem, porque o erro é cumulativo.
  primeira_divergencia: (LinhaDoExtrato & { salto: string }) | null
  linhas: LinhaDoExtrato[]
  total_de_linhas: number
}

export async function fetchExtrato(
  platformAccountId?: number,
): Promise<ExtratoResponse> {
  const { data } = await api.get<ExtratoResponse>("/saldos/extrato", {
    params: { platform_account_id: platformAccountId },
  })

  return data
}

export async function fetchSaldos(): Promise<SaldosResponse> {
  const { data } = await api.get<SaldosResponse>("/saldos")

  return data
}

export async function conferirSaldos(
  platformAccountId?: number,
): Promise<ConferenciaResponse> {
  const { data } = await api.post<ConferenciaResponse>("/saldos/conferir", {
    platform_account_id: platformAccountId,
  })

  return data
}
