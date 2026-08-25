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
