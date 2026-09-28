import { AlertTriangle, Landmark, Receipt, TrendingUp } from "lucide-react"

import {
  fetchApuracao,
  type BaseDaApuracao,
  type Classificacao,
  type DoDocumento,
  type ImpostosNaNota,
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
      "Simples Nacional: apuração sobre a receita bruta do mês, com a parcela de substituição tributária segregada no PGDAS.",
  },
  imposto: {
    titulo: "Apuração sobre o imposto da nota",
    explicacao:
      "Regime Normal: apuração pelo imposto debitado em cada nota. A receita bruta é contexto.",
  },
  mista: {
    titulo: "Dois regimes no mesmo período",
    explicacao:
      "Há notas de Simples e de Regime Normal no período. Cada mês apura pela sua própria base.",
  },
  indefinida: {
    titulo: "Regime não identificado",
    explicacao:
      "Nenhuma nota informa um regime reconhecido. Os números não constituem apuração até o regime ser mapeado.",
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

      <p className="mt-2 text-xs text-zinc-500">
        Ficam fora da apuração até o regime ser mapeado.
      </p>
    </div>
  )
}

// Os impostos que a NOTA carrega, sempre visíveis.
//
// Zero aqui é resposta, não falta de dado: emitente do Simples com CSOSN 102 não destaca
// ICMS, e o XML da NF-e confirma isso em vez de supor. É para poder dizer exatamente essa
// frase que a proveniência aparece ao lado.
function ImpostosDaNota({
  impostos,
  documento,
}: {
  impostos: ImpostosNaNota
  documento: DoDocumento
}) {
  const linhas: Array<[string, string]> = [
    ["Base de ICMS", impostos.base_icms],
    ["ICMS", impostos.icms],
    ["ICMS-ST", impostos.icms_st],
    ["IPI", impostos.ipi],
    ["ISSQN", impostos.issqn],
    ["PIS", impostos.pis],
    ["COFINS", impostos.cofins],
  ]

  const tudo_zero = linhas.every(([, valor]) => numero(valor) === 0)

  return (
    <div className="rounded-lg border border-zinc-800 bg-zinc-900/50 p-5">
      <div className="flex flex-wrap items-baseline justify-between gap-2">
        <h2 className="text-sm font-medium text-zinc-200">Impostos nas notas do período</h2>

        <span className={`text-xs ${documento.notas >= documento.de ? "text-emerald-400" : "text-amber-400"}`}>
          {documento.notas} de {documento.de} notas lidas do XML da NF-e
        </span>
      </div>

      <div className="mt-4 grid grid-cols-2 gap-3 sm:grid-cols-4 lg:grid-cols-7">
        {linhas.map(([nome, valor]) => (
          <div key={nome}>
            <p className="text-xs text-zinc-500">{nome}</p>
            <p className={`mt-1 font-medium ${numero(valor) > 0 ? "text-zinc-100" : "text-zinc-500"}`}>
              {brl(valor)}
            </p>
          </div>
        ))}
      </div>

      {/* Curto, mas não removível: sem o aviso, alguém soma isto como imposto recolhido e
          erra por cerca de um terço da receita. */}
      <div className="mt-4 flex flex-wrap items-baseline justify-between gap-2 border-t border-zinc-800 pt-4">
        <p className="text-xs text-zinc-500" title="Estimativa do IBPT exigida pela Lei da Transparência, impressa no rodapé da nota.">
          Tributos aproximados · <span className="text-amber-400/90">não é imposto recolhido</span>
        </p>
        <p className="font-medium text-zinc-400">{brl(impostos.total_aproximado_de_tributos)}</p>
      </div>

      {tudo_zero && (
        <p className="mt-3 text-xs text-zinc-500">
          Sem imposto destacado nas notas — o esperado no Simples Nacional.
        </p>
      )}
    </div>
  )
}

// CFOP e natureza da operação: o que a nota diz que a operação É.
function Classificacoes({
  titulo,
  itens,
  vazio,
}: {
  titulo: string
  itens: Classificacao[]
  vazio: string
}) {
  return (
    <div className="rounded-lg border border-zinc-800 bg-zinc-900/50 p-5">
      <h2 className="text-sm font-medium text-zinc-200">{titulo}</h2>

      {itens.length === 0 ? (
        <p className="mt-3 text-sm text-zinc-500">{vazio}</p>
      ) : (
        <>
          <div className="mt-4 overflow-x-auto">
            <table className="w-full text-sm">
              <tbody className="divide-y divide-zinc-800">
                {itens.map((item) => (
                  <tr key={item.valor ?? "sem"}>
                    <td className="py-2 pr-4">
                      {item.valor ?? <span className="text-amber-400">não informado</span>}
                    </td>
                    <td className="py-2 px-4 text-right text-zinc-400">{item.notas} nota(s)</td>
                    <td className="py-2 pl-4 text-right text-zinc-100">{brl(item.receita)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          {/* Curto, mas não removível: sem ele a soma passando da receita bruta parece
              divergência. */}
          <p className="mt-3 text-xs text-zinc-500">
            Nota com mais de um valor conta em cada linha, então a soma pode passar da
            receita bruta.
          </p>
        </>
      )}
    </div>
  )
}

// Quantas notas do mês vieram do XML da NF-e.
//
// Amarelo quando falta alguma, e não vermelho: número parcial não é erro, é leitura em
// andamento — o ciclo varre em lotes e o Tiny bloqueia por excesso de acesso. Mas quem
// olha um imposto zerado precisa saber se a nota foi lida.
function Documento({ do_documento }: { do_documento: DoDocumento }) {
  const completo = do_documento.notas >= do_documento.de

  return (
    <td
      className={`px-4 py-3 text-right ${completo ? "text-emerald-400" : "text-amber-400"}`}
      title={
        completo
          ? "Todos os números deste mês vieram do XML da NF-e."
          : "Parte dos números vem do ERP. A leitura do XML roda em lotes."
      }
    >
      {do_documento.notas} de {do_documento.de}
    </td>
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
            {/* De onde vieram os números. Sempre visível, inclusive no Simples: é aqui
                que "o imposto está zero" deixa de ser ambíguo entre "a nota diz zero" e
                "ninguém leu a nota". */}
            <th className="px-4 py-3 text-right">Lidas do documento</th>
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
              <Documento do_documento={mes.do_documento} />
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
          <span className="font-medium text-amber-300">RBT12 parcial:</span> há{" "}
          {rbt12.meses_com_dados} mês(es) de notas, e a conta pede 12. Nesse ritmo, o ano fecharia
          em <span className="font-medium text-zinc-100">{brl(rbt12.projecao_anual)}</span> —
          projeção, não apuração.
        </div>
      )}

      {data.cobertura.sem_bloco_fiscal > 0 && (
        <div className="rounded-lg border border-zinc-800 bg-zinc-900/50 p-4 text-sm text-zinc-300">
          {data.cobertura.sem_bloco_fiscal} de {data.cobertura.notas} notas sem detalhe fiscal,
          somando {brl(data.cobertura.receita_sem_detalhe)}. Aparecem como{" "}
          <span className="text-amber-400">indefinido</span> por falta de CSOSN e de valor de ST.
        </div>
      )}

      {/* Os impostos da nota, SEMPRE. Antes eles só apareciam quando a base era imposto, e
          num cliente do Simples ficavam escondidos — exatamente a resposta que alguém abre
          esta tela para ver. "Coluna de zero ensina a ignorar a coluna" valia para a tabela
          mensal; esconder o número inteiro é outra coisa, e foi um erro meu. */}
      <ImpostosDaNota impostos={data.total.impostos_na_nota} documento={data.total.do_documento} />

      <Classificacoes titulo="Por CFOP" itens={data.por_cfop} vazio="Nenhum CFOP nas notas do período." />

      <Classificacoes
        titulo="Por natureza da operação"
        itens={data.por_natureza}
        vazio="Nenhuma natureza da operação nas notas do período. A leitura do XML roda em lotes."
      />

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
            Faturamento de todos os canais de venda.
          </p>
        </div>
      )}
    </div>
  )
}
