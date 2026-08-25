import { api } from "./client"

export interface Movimentacao {
  id: number
  data: string
  plataforma: string | null
  valor: string
  direcao: "credit" | "debit"
  tipo: string
  // O número do pedido no marketplace — é por ele que a pessoa acha a venda lá
  // e a nota no Tiny. Nem todo lançamento tem: um repasse para o banco não é
  // de nenhum pedido em particular.
  pedido: string | null
  // Nosso identificador interno. Serve para suporte, não para leitura.
  referencia: string
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
