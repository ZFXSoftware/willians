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

export interface ConferenciaResponse {
  resumo: Record<string, number>
  detalhes: Array<{
    platform_account_id: number
    plataforma: string
    situacao: string
    mensagem?: string
    diferenca?: string
  }>
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
