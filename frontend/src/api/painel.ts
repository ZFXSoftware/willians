import { api } from "./client"

export interface Movimentacao {
  id: number
  data: string
  descricao: string
  plataforma: string | null
  valor: string
  direcao: "credit" | "debit"
  tipo: string
  status: string
}

export interface Painel {
  saldo_virtual: string
  a_receber: string
  conciliado: string
  divergencias: string
  divergencias_abertas: number
  contas_conectadas: number
  total_contas: number
  ultima_conciliacao: string | null
  ultimas_movimentacoes: Movimentacao[]
}

export async function fetchPainel(): Promise<Painel> {
  const { data } = await api.get<Painel>("/painel")

  return data
}
