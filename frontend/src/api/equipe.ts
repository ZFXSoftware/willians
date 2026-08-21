import { api } from "./client"
import type { SessionPayload } from "../store/useAuth"

export type Papel = "owner" | "admin" | "member" | "viewer"

export interface Membro {
  id: number
  user_id: number
  nome: string
  email: string
  papel: Papel
  escreve: boolean
  status: string
  ultimo_acesso: string | null
  sou_eu: boolean
}

export interface ConvitePendente {
  id: number
  email: string
  papel: Papel
  situacao: string
  expira_em: string
  criado_em: string
  convidado_por: string | null
}

export interface EquipeResponse {
  membros: Membro[]
  convites: ConvitePendente[]
  papeis: Array<{ valor: Papel; rotulo: string; escreve: boolean }>
  meu_papel: Papel | null
}

/** O `link` só existe nesta resposta: o banco guarda apenas o hash do token. */
export interface ConviteCriado extends ConvitePendente {
  link: string
  aviso: string
}

export async function fetchEquipe(): Promise<EquipeResponse> {
  const { data } = await api.get<EquipeResponse>("/equipe")

  return data
}

export async function convidar(email: string, role: Papel): Promise<ConviteCriado> {
  const { data } = await api.post<ConviteCriado>("/equipe/convidar", { email, role })

  return data
}

export async function revogarConvite(id: number): Promise<void> {
  await api.delete(`/equipe/convites/${id}`)
}

export async function alterarPapel(membroId: number, role: Papel): Promise<Membro> {
  const { data } = await api.patch<Membro>(`/equipe/membros/${membroId}`, { role })

  return data
}

export async function removerMembro(membroId: number): Promise<void> {
  await api.delete(`/equipe/membros/${membroId}`)
}

// --- Recebimento do convite (público, sem sessão) --------------------------

export interface ConviteRecebido {
  empresa: string
  email: string
  papel: Papel
  expira_em: string
  usuario_existente: boolean
}

export async function lerConvite(token: string): Promise<ConviteRecebido> {
  const { data } = await api.get<ConviteRecebido>(`/convites/${token}`)

  return data
}

/**
 * Dois desfechos possíveis, e a tela precisa distinguir:
 *
 * - quem já tinha conta ganha acesso à empresa e continua com a senha dela;
 * - quem não tinha cria a conta e entra na hora.
 */
export type AceiteDeConvite =
  | { ja_tinha_conta: true; empresa: string; mensagem: string }
  | ({ ja_tinha_conta?: false } & SessionPayload)

export async function aceitarConvite(
  token: string,
  dados: { name?: string; password?: string },
): Promise<AceiteDeConvite> {
  const { data } = await api.post<AceiteDeConvite>(`/convites/${token}/aceitar`, dados)

  return data
}
