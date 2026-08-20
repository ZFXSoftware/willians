import { api } from "./client"

export type TipoCampo = "texto" | "booleano" | "opcao"

export type OrigemValor = "configuracao" | "ambiente" | "padrao" | "faltando"

export interface OpcaoCampo {
  valor: string
  rotulo: string
}

export interface CampoConfiguracao {
  chave: string
  rotulo: string
  ajuda: string | null
  tipo: TipoCampo
  opcoes: OpcaoCampo[] | null
  secreto: boolean
  obrigatorio: boolean
  preenchido: boolean
  origem: OrigemValor
  variavel_de_ambiente: string
  /** Campos secretos nunca voltam preenchidos: o servidor devolve `null`. */
  valor: string | null
  /** Últimos caracteres de um segredo já gravado, para conferência. */
  pista: string | null
}

export interface ProvedorConfiguracao {
  chave: string
  rotulo: string
  ajuda: string
  documentacao: string
  configurado: boolean
  campos: CampoConfiguracao[]
  pendencias: string[]
}

export interface ConfiguracoesResponse {
  provedores: ProvedorConfiguracao[]
  urls_de_retorno: Record<string, string | null>
}

export async function fetchConfiguracoes(): Promise<ConfiguracoesResponse> {
  const { data } = await api.get<ConfiguracoesResponse>("/integracoes/configuracoes")

  return data
}

/** Campo enviado vazio apaga a configuração e devolve a vez ao ambiente. */
export async function salvarConfiguracao(
  provedor: string,
  valores: Record<string, string>,
): Promise<ProvedorConfiguracao> {
  const { data } = await api.put<ProvedorConfiguracao>(
    `/integracoes/configuracoes/${provedor}`,
    { valores },
  )

  return data
}

export async function apagarConfiguracao(
  provedor: string,
  chave: string,
): Promise<ProvedorConfiguracao> {
  const { data } = await api.delete<ProvedorConfiguracao>(
    `/integracoes/configuracoes/${provedor}/${chave}`,
  )

  return data
}
