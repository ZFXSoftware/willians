import { AlertTriangle, Landmark, Receipt, TrendingUp } from "lucide-react"

import {
  fetchApuracao,
  type BaseDaApuracao,
  type MesDaApuracao,
  type RegimeDaApuracao,
} from "../../api/apuracao"
import { useResource } from "../../hooks/useResource"
import { brl, numero } from "../../lib/format"
import { Carregando, ErroAoCarregar, Vazio } from "../../components/Estados"

// O que cada base apura. A tela inteira muda de assunto conforme isto: no
// Simples o número que vale é a receita bruta do mês; no Regime Normal é o
// imposto debitado na nota, e a receita vira contexto. Liderar pela receita num
// cliente de Regime Normal esconderia o imposto devido.
const BASES: Record<BaseDaApuracao, { titulo: string; explicacao: string }> = {
  receita: {
    titulo: "Apuração sobre a receita",
    explicacao:
      "Simples Nacional: o imposto é apurado sobre a receita bruta do mês, e a parcela com substituição tributária entra segregada no PGDAS. O imposto dentro da nota sai zero — e isso está correto.",
  },
  imposto: {
    titulo: "Apuração sobre o imposto da nota",
    explicacao:
      "Regime Normal: o que vale é o imposto debitado em cada nota, com a base de cálculo ao lado. A receita bruta aqui é contexto, não a apuração.",
  },
  mista: {
    titulo: "Dois regimes no mesmo período",
    explicacao:
      "Há notas de Simples e de Regime Normal na janela. Cada mês apura pela sua base — somar as duas num número só seria inventar. Veja a coluna de regime em cada mês.",
  },
  indefinida: {
    titulo: "Regime não identificado",
    explicacao:
      "Nenhuma nota informa um regime que saibamos ler. Os números aparecem, mas nenhum deles é a apuração enquanto o regime não for mapeado.",
  },
}

function Cartao({
  titulo,
  valor,
  detalhe,
  Icone,
  tom = "normal",
}: {
  titulo: string
  valor: string
  detalhe?: string
  Icone: typeof Receipt
  tom?: "normal" | "alerta"
}) {
  const borda = tom === "alerta" ? "border-amber-500/30" : "border-zinc-800"

  return (
    <div className={`rounded-lg border ${borda} bg-zinc-900/50 p-4`}>
      <div className="flex items-center gap-2 text-xs uppercase tracking-wide text-zinc-400">
        <Icone className="h-4 w-4" />
        {titulo}
      </div>

      <div className="mt-2 text-2xl font-semibold text-zinc-100">{valor}</div>

      {detalhe && <div className="mt-1 text-xs text-zinc-400">{detalhe}</div>}
    </div>
  )
}

function Regimes({ regimes }: { regimes: RegimeDaApuracao[] }) {
  // Regime que não reconhecemos NÃO vira Simples por omissão, e por isso ele
  // aparece com o texto cru que veio da nota: sem isso ninguém sabe o que
  // mapear, e apurar Regime Normal como Simples esconderia imposto devido.
  const desconhecidos = regimes.filter((r) => r.regime === null)

  if (desconhecidos.length === 0) return null

  return (
    <div className="rounded-lg border border-amber-500/30 bg-amber-500/5 p-4">
      <div className="flex items-center gap-2 text-sm font-medium text-amber-300">
        <AlertTriangle className="h-4 w-4" />
        Regime tributário não identificado
      </div>

      {desconhecidos.map((regime) => (
        <div key={regime.rotulo} className="mt-2 text-sm text-zinc-300">
          {regime.notas} nota(s), {brl(regime.receita)} de receita.
          {regime.valores_crus.length > 0 && (
            <span className="text-zinc-400">
              {" "}
              A nota diz: {regime.valores_crus.map((v) => `"${v}"`).join(", ")}.
            </span>
          )}
        </div>
      ))}

      <p className="mt-2 text-xs text-zinc-400">
        Essas notas ficam fora da apuração até alguém dizer qual é o regime. Não são contadas como
        Simples por omissão.
      </p>
    </div>
  )
}

function Meses({ meses, base }: { meses: MesDaApuracao[]; base: BaseDaApuracao }) {
  const mostraImposto = base === "imposto" || base === "mista"

  return (
    <div className="overflow-x-auto rounded-lg border border-zinc-800">
      <table className="w-full text-sm">
        <thead className="bg-zinc-900/80 text-xs uppercase tracking-wide text-zinc-400">
          <tr>
            <th className="px-4 py-3 text-left">Mês</th>
            <th className="px-4 py-3 text-right">Notas</th>
            <th className="px-4 py-3 text-right">Receita bruta</th>
            <th className="px-4 py-3 text-right">Devoluções</th>
            <th className="px-4 py-3 text-right">Receita líquida</th>
            <th className="px-4 py-3 text-right">Com ST</th>
            <th className="px-4 py-3 text-right">Sem ST</th>
            <th className="px-4 py-3 text-right">Indefinido</th>
            {mostraImposto && <th className="px-4 py-3 text-right">ICMS na nota</th>}
          </tr>
        </thead>

        <tbody className="divide-y divide-zinc-800">
          {meses.map((mes) => (
            <tr key={mes.mes} className="hover:bg-zinc-900/40">
              <td className="px-4 py-3 font-medium text-zinc-200">{mes.mes}</td>
              <td className="px-4 py-3 text-right text-zinc-400">{mes.notas}</td>
              <td className="px-4 py-3 text-right text-zinc-100">{brl(mes.receita_bruta)}</td>
              <td className="px-4 py-3 text-right text-zinc-400">
                {numero(mes.devolucoes.valor) > 0 ? `− ${brl(mes.devolucoes.valor)}` : "—"}
              </td>
              <td className="px-4 py-3 text-right text-zinc-200">{brl(mes.receita_liquida)}</td>
              <td className="px-4 py-3 text-right text-zinc-300">
                {brl(mes.segregacao.com_st.receita)}
              </td>
              <td className="px-4 py-3 text-right text-zinc-300">
                {brl(mes.segregacao.sem_st.receita)}
              </td>
              {/* Indefinido só ganha destaque quando existe: pintar zero de
                  amarelo ensina a ignorar o amarelo. */}
              <td
                className={`px-4 py-3 text-right ${
                  numero(mes.segregacao.indefinido.receita) > 0 ? "text-amber-400" : "text-zinc-600"
                }`}
              >
                {brl(mes.segregacao.indefinido.receita)}
              </td>
              {mostraImposto && (
                <td className="px-4 py-3 text-right text-zinc-100">{brl(mes.impostos_na_nota.icms)}</td>
              )}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

export default function Apuracao() {
  const { data, loading, error, reload } = useResource(() => fetchApuracao())

  if (loading) return <Carregando />
  if (error) return <ErroAoCarregar mensagem={error} onRetry={reload} />
  if (!data) return <Vazio titulo="Sem apuração no período." />

  const base = data.total.base
  const explicacao = BASES[base]
  const rbt12 = data.rbt12
  const ultimo = data.meses[data.meses.length - 1]

  return (
    <div className="space-y-6">
      <div>
        <h1 className="text-xl font-semibold text-zinc-100">Apuração fiscal</h1>
        <p className="text-sm text-zinc-400">
          {data.periodo.de} a {data.periodo.ate} · {explicacao.titulo}
        </p>
      </div>

      <p className="rounded-lg border border-zinc-800 bg-zinc-900/50 p-4 text-sm text-zinc-300">
        {explicacao.explicacao}
      </p>

      <Regimes regimes={data.regimes} />

      {/* No Simples a RBT12 é o número que decide alíquota e sublimite. Vem
          antes da tabela de propósito: ler a receita do mês sem ela é ler o
          número menos importante primeiro. */}
      {(base === "receita" || base === "mista") && (
        <div className="grid gap-4 sm:grid-cols-3">
          <Cartao
            titulo="Receita 12 meses (RBT12)"
            valor={brl(rbt12.receita)}
            detalhe={
              rbt12.completo
                ? `${rbt12.percentual_do_teto}% do teto do Simples`
                : `PISO: há ${rbt12.meses_com_dados} mês(es) de notas, a conta pede 12`
            }
            Icone={Landmark}
            tom={rbt12.completo ? "normal" : "alerta"}
          />

          <Cartao
            titulo="Sublimite de ICMS/ISS"
            valor={`${rbt12.percentual_do_sublimite}%`}
            detalhe={`de ${brl(rbt12.sublimite_icms)}`}
            Icone={TrendingUp}
            tom={numero(rbt12.percentual_do_sublimite) >= 80 ? "alerta" : "normal"}
          />

          <Cartao
            titulo="Retido pelo marketplace"
            valor={brl(data.retido_pelo_marketplace)}
            detalhe="pelo extrato da plataforma, não pela nota"
            Icone={Receipt}
          />
        </div>
      )}

      {!rbt12.completo && rbt12.projecao_anual && (base === "receita" || base === "mista") && (
        <div className="rounded-lg border border-amber-500/30 bg-amber-500/5 p-4 text-sm text-zinc-300">
          <span className="font-medium text-amber-300">A RBT12 ainda não fechou doze meses.</span>{" "}
          O valor acima é piso, não total — não leia como “longe do teto”. No ritmo dos{" "}
          {rbt12.meses_com_dados} mês(es) que temos, doze meses dariam{" "}
          <span className="font-medium text-zinc-100">{brl(rbt12.projecao_anual)}</span>. Projeção,
          não apuração: serve para saber se o assunto é urgente. Quem decide o que fazer com isso é
          a contabilidade.
        </div>
      )}

      {data.cobertura.sem_bloco_fiscal > 0 && (
        <div className="rounded-lg border border-zinc-800 bg-zinc-900/50 p-4 text-sm text-zinc-300">
          {data.cobertura.sem_bloco_fiscal} de {data.cobertura.notas} notas estão sem detalhe
          fiscal, somando {brl(data.cobertura.receita_sem_detalhe)}. Elas aparecem como{" "}
          <span className="text-amber-400">indefinido</span>: sem CSOSN nem valor de ST, não dá para
          dizer se têm substituição tributária, e chutar mudaria a base declarada.
        </div>
      )}

      {data.meses.length === 0 ? (
        <Vazio titulo="Nenhuma nota no período." descricao="Nada foi emitido na janela consultada." />
      ) : (
        <Meses meses={data.meses} base={base} />
      )}

      {ultimo && (
        <div>
          <h2 className="mb-3 text-sm font-medium text-zinc-300">
            Receita por canal em {ultimo.mes}
          </h2>

          <div className="overflow-hidden rounded-lg border border-zinc-800">
            <table className="w-full text-sm">
              <tbody className="divide-y divide-zinc-800">
                {ultimo.por_canal.map((canal) => (
                  <tr key={canal.rotulo} className="hover:bg-zinc-900/40">
                    <td className="px-4 py-3 text-zinc-200">
                      {canal.rotulo}
                      {canal.intermediadores.length > 0 && (
                        <div className="text-xs text-amber-400">
                          sem mapa: {canal.intermediadores.join(", ")}
                        </div>
                      )}
                    </td>
                    <td className="px-4 py-3 text-right text-zinc-400">{canal.notas} nota(s)</td>
                    <td className="px-4 py-3 text-right text-zinc-100">{brl(canal.receita)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <p className="mt-2 text-xs text-zinc-500">
            A conciliação de repasses só enxerga o Mercado Livre. Esta é a única tela que soma o
            faturamento de todos os canais.
          </p>
        </div>
      )}
    </div>
  )
}
