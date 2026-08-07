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

export async function conectarMercadoLivre(
  platformAccountId?: number,
): Promise<{ authorization_url: string }> {
  const { data } = await api.post("/integracoes/mercado-livre/autorizar", {
    platform_account_id: platformAccountId,
  })

  return data
}

export async function desconectar(platformAccountId: number): Promise<void> {
  await api.delete("/integracoes/mercado-livre/desconectar", {
    params: { platform_account_id: platformAccountId },
  })
}
