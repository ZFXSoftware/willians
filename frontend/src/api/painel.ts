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
  // Id do pagamento no Mercado Pago. Não é o pedido, mas é o único
  // identificador que o relatório de liberações traz — e é por ele que se acha
  // o lançamento no extrato.
  pagamento: string | null
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

// As séries dos gráficos do painel. Endpoint próprio: o resumo abre a tela, isto varre a
// janela inteira, e juntar faria toda abertura pagar as duas.
export interface DiaDoPainel {
  dia: string
  vendas_quantidade: number
  vendas_valor: string
  saques: string
}

export interface CanalDoPainel {
  canal: string | null
  rotulo: string
  receita: string
}

export interface StatusDoPainel {
  status: string
  quantidade: number
}

export interface ParteDoBruto {
  parte: string
  valor: string
}

export interface SeriesDoPainel {
  periodo: { de: string; ate: string; dias: number }
  por_dia: DiaDoPainel[]
  por_canal: CanalDoPainel[]
  conciliacao: StatusDoPainel[]
  composicao: ParteDoBruto[]
}

export async function fetchSeries(dias = 90): Promise<SeriesDoPainel> {
  const { data } = await api.get<SeriesDoPainel>("/painel/series", { params: { dias } })

  return data
}
