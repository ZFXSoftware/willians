import { api, gatewayApi } from "./client"

// O que o sistema executou, e o que está executando.
//
// São duas fontes porque são duas naturezas: a FILA vive no gateway (Redis) e
// só sabe do agora; o HISTÓRICO vive no banco e só sabe do passado. Juntar as
// duas na mesma tela é o que responde "está rodando?", "terminou?" e "deu
// certo?" — perguntas que hoje só tinham resposta comparando contadores.

export interface JobNaFila {
  id: string
  nome: string
  criado_em: string | null
  iniciado_em: string | null
  tentativa: number
  periodo: string | null
}

export interface Filas {
  ativos: JobNaFila[]
  esperando: JobNaFila[]
  agendados: JobNaFila[]
  // Contagem global, incluindo outras organizações: é o que explica uma espera
  // longa sem nenhum job seu na frente.
  total_na_fila: Record<string, number>
}

export interface ExecucaoConciliacaoHistorico {
  id: number
  status: string
  plataforma: string | null
  iniciada_em: string | null
  terminada_em: string | null
  duracao_s: number | null
  repasses: number | null
  conferidos: number | null
  divergentes: number | null
  periodo: string
  erro: string | null
}

export interface Processos {
  conciliacoes: ExecucaoConciliacaoHistorico[]
  fiscal: {
    importacao: Record<string, unknown> | null
    envio_ao_omie: Record<string, unknown> | null
  }
  ultima_conciliacao: string | null
}

export async function fetchProcessos(): Promise<Processos> {
  const { data } = await api.get<Processos>("/processos")

  return data
}

export async function fetchFilas(): Promise<Filas> {
  const { data } = await gatewayApi.get<Filas>("/filas")

  return data
}

/** Há trabalho desta organização na fila agora? */
export function ocupada(filas: Filas | null | undefined): boolean {
  if (!filas) return false

  return filas.ativos.length > 0 || filas.esperando.length > 0
}

export const NOMES_DE_JOB: Record<string, string> = {
  processar: "Conciliação",
  importar_notas: "Importação de notas do Tiny",
}
