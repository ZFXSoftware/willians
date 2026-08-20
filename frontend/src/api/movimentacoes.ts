import { api } from "./client"

export interface DetalheMovimentacao {
  financial_entry_id: number
  external_id?: string
  resultado: string
  mensagem: string
  codigo_lancamento_omie?: number | null
}

export interface ResultadoMovimentacao {
  status: string
  resumo: Record<string, number | boolean>
  detalhes: DetalheMovimentacao[]
}

interface Opcoes {
  dryRun?: boolean
  limite?: number
}

function corpo({ dryRun, limite }: Opcoes) {
  return {
    ...(dryRun === undefined ? {} : { dry_run: dryRun }),
    ...(limite ? { limite } : {}),
  }
}

export async function transferir(opcoes: Opcoes = {}): Promise<ResultadoMovimentacao> {
  const { data } = await api.post("/movimentacoes/transferir", corpo(opcoes))

  return data
}

export async function pagar(opcoes: Opcoes = {}): Promise<ResultadoMovimentacao> {
  const { data } = await api.post("/movimentacoes/pagar", corpo(opcoes))

  return data
}
