import { api, gatewayApi } from "./client"

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
  ultimo_lancamento: string | null
  // "pendente" é o marketplace ainda preparando o dado — nem sucesso nem
  // falha. Nulo nas contas sincronizadas antes da coluna existir.
  status_sincronizacao: "ok" | "pendente" | "falha" | null
  // O que a última sincronização fez. Ela roda em fila: a tela dispara e não
  // recebe resposta, então o resultado precisa ficar guardado.
  resumo_sincronizacao: ResumoSincronizacao | null
  erro_de_sincronizacao: string | null
  lancamentos: number
  precisa_atencao: boolean
  omie: CodigosOmie
}

export interface ResumoSincronizacao {
  em: string
  status: string
  periodo?: string
  recebidos?: number
  novos?: number
  repetidos?: number
  recusados?: number
  // Pedidos que o marketplace devolveu na janela. É o número que separa "a
  // conta certa vende pouco" de "conectamos a conta errada".
  pedidos?: number
  lancamentos_ligados?: number
  repasses_novos?: number
  // A ingestão pode dar certo e o vínculo com os pedidos falhar. Sem eles nada
  // liga o dinheiro à nota fiscal, e a tela dizia só "concluída".
  vinculo_erro?: string | null
}

// Os códigos do OMIE desta conta de marketplace.
//
// `efetivo` é o que vale de verdade e `origem` diz de onde veio — em branco
// aqui não significa faltando: pode estar herdando o padrão da empresa.
export interface CodigosOmie {
  cliente_fornecedor_id: string | null
  conta_corrente_id: string | null
  efetivo: {
    cliente_fornecedor_id: string | number | null
    conta_corrente_id: string | number | null
  }
  origem: {
    cliente_fornecedor_id: string
    conta_corrente_id: string
  }
}

export interface IntegracoesResponse {
  items: Integracao[]
  resumo: {
    total: number
    conectadas: number
    precisam_atencao: number
  }
  plataformas_implementadas: string[]
  notas_fiscais: NotasFiscais
}

// As notas do Tiny. Não são uma conta de marketplace, mas respondem à mesma
// pergunta da tela: o que já entrou e o que falta entrar.
export interface NotasFiscais {
  configurado: boolean
  total: number
  // Nota sem pedido não amarra a corrente pedido -> NF -> título.
  com_pedido: number
  ultima_importacao: string | null
  enviadas_ao_omie: number
  ultimo_resultado: ResultadoImportacao | null
  ultimo_envio: UltimoEnvioOmie | null
}

// O envio ao OMIE continua pelo ciclo automático com a tela fechada. Este é o
// carimbo da última leva — é ele que responde "ainda está acontecendo?".
export interface UltimoEnvioOmie {
  em: string
  enviadas?: number
  falhas_seguidas?: number
  ultimo_erro?: string | null
}

// A importação roda em fila: o botão recebe "enfileirado" e nada mais. É este
// registro que permite dizer se deu certo, quantas vieram, ou o que falhou.
export interface ResultadoImportacao {
  em: string
  periodo?: string
  lidas?: number
  criadas?: number
  atualizadas?: number
  pedidos_criados?: number
  sem_pedido?: number
  sem_plataforma?: number
  erro?: string | null
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

// Busca do marketplace e concilia em seguida.
//
// Vai pelo GATEWAY, e não direto no Rails, por causa do tempo: na primeira
// execução de uma conta do Mercado Livre o relatório de liberações ainda está
// sendo gerado do lado deles, e a espera passa de um minuto — muito além do
// que o proxy aguenta. O gateway enfileira e responde na hora; quem acompanha
// o resultado é a própria tela, recarregando.
export async function sincronizar(platformAccountId: number): Promise<{ job_id: string }> {
  const { data } = await gatewayApi.post("/conciliacoes/processar", {
    platform_account_id: platformAccountId,
    forcar: true,
  })

  return data
}

// Some com a conta de vez.
//
// Sem `confirmar`, o backend RECUSA quando há histórico e devolve as
// contagens — é o que permite mostrar "apagar isto leva junto N lançamentos"
// antes de perguntar. Com `confirmar`, apaga em cascata: existe porque uma
// conta conectada por engano traz lançamentos que nunca deveriam ter entrado
// no razão, e arquivar não os tira do saldo nem da conciliação.
export async function removerConta(
  platformAccountId: number,
  confirmar = false,
): Promise<void> {
  await api.delete(`/integracoes/contas/${platformAccountId}`, {
    params: confirmar ? { confirmar: true } : undefined,
  })
}

// Tira da operação sem destruir nada: sai da conciliação e da sincronização,
// e o que já entrou no razão continua lá.
export async function arquivarConta(platformAccountId: number): Promise<void> {
  await api.post(`/integracoes/contas/${platformAccountId}/arquivar`)
}

export async function desconectar(platformAccountId: number): Promise<void> {
  await api.delete("/integracoes/desconectar", {
    params: { platform_account_id: platformAccountId },
  })
}

// Códigos do OMIE desta conta de marketplace.
//
// Uma empresa que vende no Mercado Livre, na Amazon e na Shopee precisa de um
// cliente/fornecedor e de uma conta corrente por marketplace — o campo único
// da tela da empresa é só o padrão de quem não preencheu aqui.
//
// String vazia apaga o código e devolve a conta ao padrão da empresa.
export async function salvarCodigosOmie(
  platformAccountId: number,
  omie: { cliente_fornecedor_id?: string; conta_corrente_id?: string },
): Promise<{ id: number; omie: Record<string, string | null> }> {
  const { data } = await api.put(
    `/integracoes/contas/${platformAccountId}/omie`,
    { omie },
  )

  return data
}

// Importa as notas fiscais do Tiny para o nosso banco.
//
// Passa pelo gateway, que responde 202 na hora: são milhares de notas em
// páginas de 100, e a leitura inteira não cabe no tempo de uma requisição de
// navegador. NÃO toca no OMIE — isso é outro passo, com trava própria.
export async function importarNotas(dias = 30): Promise<{ job_id: string }> {
  const fim = new Date()
  const inicio = new Date(fim.getTime() - dias * 24 * 60 * 60 * 1000)

  const { data } = await gatewayApi.post("/fiscal/notas/importar", {
    start_date: inicio.toISOString().slice(0, 10),
    end_date: fim.toISOString().slice(0, 10),
  })

  return data
}

// Os cadastros do OMIE, para a tela oferecer uma LISTA em vez de um campo onde
// se cola um código copiado de um terminal.
export type TipoOpcaoOmie = "clientes" | "contas_correntes" | "categorias"

export interface OpcaoOmie {
  codigo: string
  nome: string
}

export async function opcoesOmie(
  tipo: TipoOpcaoOmie,
  busca?: string,
): Promise<OpcaoOmie[]> {
  const { data } = await api.get<{ items: OpcaoOmie[] }>("/integracoes/omie/opcoes", {
    params: { tipo, busca },
  })

  return data.items
}

export interface ResultadoEnvioOmie {
  simulado: boolean
  previstas: number
  enviadas: number
  // Quantas ainda faltam depois desta execução. O envio vai em lotes: cada
  // nota são duas chamadas ao OMIE com pausa entre elas, e milhares não cabem
  // numa requisição só.
  pendentes: number
  sem_comprador: number
  falhas: number
  amostra?: Array<{ nf: string; comprador: string; valor: number }>
  erros?: string[]
  aviso?: string
  motivo_da_simulacao?: string
}

// Simula por padrão. Só grava com `aplicar` explícito — e ainda assim a trava
// OMIE_ALLOW_WRITES vale por baixo.
export async function enviarNotasAoOmie(
  opcoes: { aplicar?: boolean; limite?: number } = {},
): Promise<ResultadoEnvioOmie> {
  const { data } = await api.post("/fiscal/notas/enviar-ao-omie", {
    aplicar: opcoes.aplicar ?? false,
    limite: opcoes.limite,
  })

  return data
}
