// A API devolve decimais como string para não perder precisão em ponto
// flutuante. A conversão para número acontece só na formatação.

const BRL = new Intl.NumberFormat("pt-BR", {
  style: "currency",
  currency: "BRL",
})

export function brl(value: string | number | null | undefined): string {
  if (value === null || value === undefined || value === "") return "—"

  const n = typeof value === "number" ? value : Number(value)

  return Number.isNaN(n) ? "—" : BRL.format(n)
}

export function numero(value: string | number | null | undefined): number {
  if (value === null || value === undefined || value === "") return 0

  const n = typeof value === "number" ? value : Number(value)

  return Number.isNaN(n) ? 0 : n
}

export function dataBR(value: string | null | undefined): string {
  if (!value) return "—"

  const d = new Date(value)

  return Number.isNaN(d.getTime())
    ? "—"
    : d.toLocaleDateString("pt-BR", { day: "2-digit", month: "2-digit", year: "numeric" })
}

export function dataHoraBR(value: string | null | undefined): string {
  if (!value) return "—"

  const d = new Date(value)

  return Number.isNaN(d.getTime())
    ? "—"
    : d.toLocaleString("pt-BR", { dateStyle: "short", timeStyle: "short" })
}

export function desde(value: string | null | undefined): string {
  if (!value) return "nunca"

  const d = new Date(value).getTime()

  if (Number.isNaN(d)) return "nunca"

  const min = Math.floor((Date.now() - d) / 60000)

  if (min < 1) return "agora"
  if (min < 60) return `há ${min} min`

  const horas = Math.floor(min / 60)
  if (horas < 24) return `há ${horas}h`

  return `há ${Math.floor(horas / 24)}d`
}

const ROTULOS: Record<string, string> = {
  matched: "Conciliado",
  divergent: "Divergente",
  // NÃO é "alguém precisa revisar": é "não deu para comparar".
  //
  // O motor recusa a comparação quando a cobertura está incompleta — venda sem
  // nota, nota sem título no OMIE. "Revisão manual" mandava o operador abrir a
  // linha para decidir algo que não há como decidir: o que falta é dado, e o
  // conserto é antes, não ali.
  manual_review: "Sem comparação",
  pending: "Pendente",
  resolved: "Resolvida",
  open: "Aberta",
  analyzing: "Em análise",
  ignored: "Ignorada",
  valor_divergente: "Valor divergente",
  titulo_nao_encontrado: "Título não encontrado",
  mercado_livre: "Mercado Livre",
  shopee: "Shopee",
  amazon: "Amazon",
  magalu: "Magalu",
  connected: "Conectada",
  expired: "Expirada",
  revoked: "Revogada",
  active: "Ativa",
  inactive: "Inativa",
  error: "Com erro",

  // Tipos de lançamento do razão. Antes a tela mostrava o valor cru do banco
  // com `humanize` — "Refund", "Settlement" —, que é o nome que o programador
  // deu, em inglês, e não o que aconteceu com o dinheiro.
  sale: "Venda",
  refund: "Estorno",
  fee: "Tarifa",
  settlement: "Repasse para o banco",
  chargeback: "Contestação",
  dispute: "Disputa",
  transfer: "Transferência",
  payment: "Pagamento",
  adjustment: "Ajuste",
  future_receivable: "A receber",
  unidentified: "Não identificado",
  settled: "Liquidado",
  reconciled: "Conciliado",
  cancelled: "Cancelado",
}

export function rotulo(chave: string | null | undefined): string {
  if (!chave) return "—"

  return ROTULOS[chave] ?? chave.replace(/_/g, " ")
}
