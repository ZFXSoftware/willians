import { api } from "./client"

// Sobre o que o regime apura. É isto que decide qual número a tela mostra
// primeiro: no Simples o imposto é apurado sobre a RECEITA bruta do mês e a nota
// sai com imposto zerado; no Regime Normal a nota carrega imposto de verdade e é
// a soma dele que vale. Liderar pela receita num cliente de Regime Normal
// esconderia o imposto devido.
export type BaseDaApuracao = "receita" | "imposto" | "mista" | "indefinida"

export type Tributacao = "com_st" | "sem_st" | "indefinido"

export interface FatiaDaSegregacao {
  notas: number
  receita: string
}

export interface ImpostosNaNota {
  base_icms: string
  icms: string
  icms_st: string
  ipi: string
  issqn: string
}

export interface CanalDaReceita {
  canal: string | null
  rotulo: string
  notas: number
  receita: string
  // Os nomes de intermediador que ninguém mapeou ainda. Sem eles, "sem canal:
  // 23 notas" não diz o que fazer.
  intermediadores: string[]
}

export interface RegimeDaApuracao {
  regime: string | null
  rotulo: string
  base: BaseDaApuracao | null
  notas: number
  receita: string
  // O valor CRU do regime que não reconhecemos. Regime desconhecido não vira
  // Simples por omissão — e sem o texto exato ninguém sabe o que mapear.
  valores_crus: string[]
}

export interface MesDaApuracao {
  mes: string
  notas: number
  receita_bruta: string
  receita_liquida: string
  base: BaseDaApuracao
  devolucoes: { notas: number; valor: string }
  segregacao: Record<Tributacao, FatiaDaSegregacao>
  impostos_na_nota: ImpostosNaNota
  por_canal: CanalDaReceita[]
  por_regime: RegimeDaApuracao[]
}

// A receita bruta dos últimos 12 meses: no Simples é ela que decide alíquota e
// sublimite. `completo` existe porque um acumulado PARCIAL exibido como ano
// fechado diz "longe do teto" quando a conta nem cobriu o ano — e isso é pior
// que não mostrar nada.
export interface Rbt12 {
  de: string
  ate: string
  receita: string
  meses_com_dados: number
  completo: boolean
  sublimite_icms: string
  teto_simples: string
  percentual_do_sublimite: string
  percentual_do_teto: string
  projecao_anual: string | null
}

export interface ApuracaoResponse {
  periodo: { de: string; ate: string }
  meses: MesDaApuracao[]
  total: Omit<MesDaApuracao, "mes" | "devolucoes" | "receita_liquida" | "por_canal" | "por_regime">
  cobertura: {
    notas: number
    com_bloco_fiscal: number
    sem_bloco_fiscal: number
    receita_sem_detalhe: string
  }
  rbt12: Rbt12
  // O que o marketplace retém de imposto, pelo extrato DELE. Zero aqui é
  // resposta — o Mercado Livre não retém imposto do vendedor —, não falta de
  // dado.
  retido_pelo_marketplace: string
  regimes: RegimeDaApuracao[]
}

export async function fetchApuracao(params?: {
  de?: string
  ate?: string
}): Promise<ApuracaoResponse> {
  const query = new URLSearchParams()

  if (params?.de) query.set("de", params.de)
  if (params?.ate) query.set("ate", params.ate)

  const sufixo = query.toString() ? `?${query.toString()}` : ""

  const { data } = await api.get<ApuracaoResponse>(`/fiscal/apuracao${sufixo}`)

  return data
}
