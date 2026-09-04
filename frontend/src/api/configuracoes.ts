import { api } from "./client"

export type TipoCampo = "texto" | "booleano" | "opcao" | "data"

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
  /** Este valor é só o PADRÃO: cada conta de marketplace pode ter o seu. */
  por_conta: boolean
  /** Cadastro do OMIE que preenche este campo; habilita a busca pelo nome. */
  fonte: "clientes" | "contas_correntes" | "categorias" | null
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

// De qual canal veio cada nota.
//
// A NF-e declara quem intermediou a venda, mas o nome é o que o cliente
// escolheu usar. Numa base real apareceram "Mercado Livre", "Shopee",
// "Magalu", "TikTok" — e "Alma teen", que é venda de balcão emitida como
// digital por exigência fiscal e não é marketplace nenhum. Nenhum código
// adivinha isso; quem opera diz, uma vez.
export interface CanalEncontrado {
  nome: string
  cnpj: string | null
  notas: number
  canal: string | null
}

export interface CanaisResponse {
  items: CanalEncontrado[]
  opcoes: Array<{ canal: string; rotulo: string }>
  // Enquanto um nome estiver sem canal, as notas dele não viram pedido e não
  // entram em conciliação nenhuma.
  sem_canal: number
  // Notas que o ciclo automático ainda não perguntou ao Tiny. A lista cresce
  // sozinha nas primeiras horas de um cliente novo.
  aguardando_leitura: number
}

export async function fetchCanais(): Promise<CanaisResponse> {
  const { data } = await api.get<CanaisResponse>("/integracoes/canais")

  return data
}

/** Canal vazio desfaz o mapeamento daquele nome. */
export async function mapearCanal(nome: string, canal: string): Promise<CanaisResponse> {
  const { data } = await api.put<CanaisResponse>("/integracoes/canais", { nome, canal })

  return data
}

// O certificado digital A1 da empresa.
//
// O arquivo entra e nunca mais sai: não existe rota de download, e o que vem
// de volta é só o resumo. Um .pfx é a identidade digital da empresa.
export interface ResumoCertificado {
  titular: string | null
  cnpj: string | null
  valido_de: string | null
  valido_ate: string | null
  dias_para_vencer: number | null
  vencido: boolean
}

export interface CertificadoResponse {
  configurado: boolean
  certificado: ResumoCertificado | null
  // Vem do backend porque a regra é dele: trinta dias antes é prazo para
  // renovar sem correria, e a tela não deveria precisar saber esse número.
  aviso: string | null
}

export async function fetchCertificado(): Promise<CertificadoResponse> {
  const { data } = await api.get<CertificadoResponse>("/integracoes/certificado")

  return data
}

export async function enviarCertificado(
  arquivo: File,
  senha: string,
): Promise<CertificadoResponse> {
  const corpo = new FormData()

  corpo.append("arquivo", arquivo)
  corpo.append("senha", senha)

  const { data } = await api.post<CertificadoResponse>("/integracoes/certificado", corpo)

  return data
}

export async function removerCertificado(): Promise<CertificadoResponse> {
  const { data } = await api.delete<CertificadoResponse>("/integracoes/certificado")

  return data
}
