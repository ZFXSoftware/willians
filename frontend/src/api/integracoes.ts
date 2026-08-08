import { api } from "./client"

export interface Credencial {
  status: string
  expira_em: string | null
  renovada_em: string | null
  erro: string | null
}

export interface Integracao {
  id: number
  nome: string
  plataforma: string
  status: string
  external_id: string | null
  integracao_disponivel: boolean
  conectada: boolean
  credencial: Credencial | null
  ultima_sincronizacao: string | null
  lancamentos: number
  precisa_atencao: boolean
}

export interface IntegracoesResponse {
  items: Integracao[]
  resumo: {
    total: number
    conectadas: number
    precisam_atencao: number
  }
  plataformas_implementadas: string[]
}

export async function fetchIntegracoes(): Promise<IntegracoesResponse> {
  const { data } = await api.get<IntegracoesResponse>("/integracoes")

  return data
}

// A rota usa hífen; o banco guarda a plataforma com underline.
const ROTA_POR_PLATAFORMA: Record<string, string> = {
  mercado_livre: "mercado-livre",
  shopee: "shopee",
  amazon: "amazon",
}

export function conexaoDisponivel(plataforma: string): boolean {
  return plataforma in ROTA_POR_PLATAFORMA
}

export async function conectar(
  plataforma: string,
  platformAccountId?: number,
): Promise<{ authorization_url: string }> {
  const rota = ROTA_POR_PLATAFORMA[plataforma]

  if (!rota) throw new Error(`Conexão com ${plataforma} não implementada`)

  const { data } = await api.post(`/integracoes/${rota}/autorizar`, {
    platform_account_id: platformAccountId,
  })

  return data
}

export async function desconectar(platformAccountId: number): Promise<void> {
  await api.delete("/integracoes/desconectar", {
    params: { platform_account_id: platformAccountId },
  })
}
