import type { SeriesDoPainel } from "../../api/painel"
import { brl, rotulo } from "../../lib/format"
import { Carregando, ErroAoCarregar } from "../../components/Estados"
import Linha from "../../components/graficos/Linha"
import Rosca from "../../components/graficos/Rosca"

const PERIODOS = [30, 90, 180]

const PARTES: Record<string, string> = {
  liquido: "Sobra para o vendedor",
  comissao: "Comissão",
  frete: "Frete",
  parcelamento: "Parcelamento",
}

// `29/set` — o ano não muda dentro da janela e ocuparia espaço no eixo sem informar.
function diaCurto(iso: string): string {
  const [, mes, dia] = iso.split("-")

  const meses = ["jan", "fev", "mar", "abr", "mai", "jun", "jul", "ago", "set", "out", "nov", "dez"]

  return `${dia}/${meses[Number(mes) - 1]}`
}

// No eixo, `12,4 mil` em vez de `R$ 12.430,55`: o eixo dá a ordem de grandeza e o balão
// dá o centavo.
function curto(valor: number): string {
  if (Math.abs(valor) >= 1000) return `${(valor / 1000).toFixed(1).replace(".", ",")} mil`

  return valor.toFixed(0)
}

export default function Graficos({
  dados,
  carregando,
  erro,
  recarregar,
  dias,
  aoTrocarPeriodo,
}: {
  dados: SeriesDoPainel | null
  carregando: boolean
  erro: string | null
  recarregar: () => void
  dias: number
  aoTrocarPeriodo: (dias: number) => void
}) {
  if (erro) return <ErroAoCarregar mensagem={erro} onRetry={recarregar} />

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between gap-3 flex-wrap">
        <h2 className="text-lg font-semibold">Movimento do período</h2>

        <div className="flex gap-1 bg-zinc-900 border border-zinc-800 rounded-xl p-1">
          {PERIODOS.map((p) => (
            <button
              key={p}
              onClick={() => aoTrocarPeriodo(p)}
              className={`px-3 py-1.5 rounded-lg text-xs transition ${
                p === dias ? "bg-zinc-800 text-zinc-100" : "text-zinc-400 hover:text-zinc-200"
              }`}
            >
              {p} dias
            </button>
          ))}
        </div>
      </div>

      {carregando || !dados ? (
        <Carregando texto="Montando os gráficos..." />
      ) : (
        <>
          <Cartao
            titulo="Vendas liberadas e saques para o banco"
            legenda="Ambos em reais, na mesma escala: o saque é escolhido pelo cliente e não acompanha as vendas do dia."
          >
            <Linha
              formatar={curto}
              rotuloDoX={diaCurto}
              series={[
                {
                  nome: "Vendas liberadas",
                  pontos: dados.por_dia.map((d) => ({ x: d.dia, y: Number(d.vendas_valor) })),
                },
                {
                  nome: "Saques para o banco",
                  pontos: dados.por_dia.map((d) => ({ x: d.dia, y: Number(d.saques) })),
                },
              ]}
            />
          </Cartao>

          {/* Gráfico SEPARADO, e não uma segunda escala no de cima: contagem e dinheiro
              em dois eixos no mesmo desenho inventariam uma correlação que não existe. */}
          <Cartao titulo="Número de vendas por dia">
            <Linha
              formatar={(v) => v.toFixed(0)}
              rotuloDoX={diaCurto}
              series={[
                {
                  nome: "Vendas",
                  pontos: dados.por_dia.map((d) => ({ x: d.dia, y: d.vendas_quantidade })),
                },
              ]}
            />
          </Cartao>

          <div className="grid grid-cols-1 xl:grid-cols-2 gap-4">
            <Cartao
              titulo="Faturamento por canal"
              legenda="Pelo intermediador declarado na nota fiscal — é a única leitura que vê todos os canais, e não só o Mercado Livre."
            >
              <Rosca
                formatar={(v) => brl(String(v))}
                fatias={dados.por_canal.map((c) => ({
                  rotulo: c.rotulo,
                  valor: Number(c.receita),
                }))}
              />
            </Cartao>

            <Cartao
              titulo="Para onde vai o bruto"
              legenda="Do Mercado Livre, que é de onde vem o extrato. As quatro partes somam o bruto do período — o faturamento ao lado é maior porque inclui os outros canais."
            >
              <Rosca
                formatar={(v) => brl(String(v))}
                fatias={dados.composicao.map((p) => ({
                  rotulo: PARTES[p.parte] ?? p.parte,
                  valor: Number(p.valor),
                }))}
              />
            </Cartao>

            <Cartao
              titulo="Situação dos repasses"
              legenda="Um por repasse, no estado atual da conferência."
            >
              <Rosca
                formatar={(v) => `${v} repasse${v === 1 ? "" : "s"}`}
                fatias={dados.conciliacao.map((c) => ({
                  rotulo: rotulo(c.status),
                  valor: c.quantidade,
                }))}
                vazio="Nenhum repasse conferido ainda."
              />
            </Cartao>
          </div>
        </>
      )}
    </div>
  )
}

function Cartao({
  titulo,
  legenda,
  children,
}: {
  titulo: string
  legenda?: string
  children: React.ReactNode
}) {
  return (
    <div className="bg-zinc-900 border border-zinc-800 rounded-3xl p-5 shadow-xl">
      <h3 className="text-sm font-medium text-zinc-200">{titulo}</h3>
      {legenda && <p className="text-xs text-zinc-500 mt-1">{legenda}</p>}

      <div className="mt-4">{children}</div>
    </div>
  )
}
