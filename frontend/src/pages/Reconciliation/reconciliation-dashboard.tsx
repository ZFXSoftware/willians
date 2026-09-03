import { Fragment, useState } from "react"
import { Link } from "react-router-dom"
import { RefreshCw, Search } from "lucide-react"

import {
  fetchRegistros,
  janelaDe,
  PERIODOS,
  processarConciliacao,
  type ExecucaoConciliacao,
  type FiltrosRegistros,
} from "../../api/conciliacoes"
import { fetchFilas, ocupada } from "../../api/processos"
import { errorMessage } from "../../api/client"
import { useResource } from "../../hooks/useResource"
import { brl, dataHoraBR, desde, rotulo } from "../../lib/format"
import { Carregando, ErroAoCarregar, Selo, Vazio } from "../../components/Estados"

const PLATAFORMAS = ["mercado_livre", "shopee", "amazon", "magalu"]

const STATUS = ["matched", "divergent", "manual_review", "pending"]

const ESPERA_MS = 4000

const ESPERA_MAXIMA = 45 // 3 minutos: a execução lê o OMIE inteiro antes

const dorme = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

// Explica o desfecho da última execução em uma frase.
//
// A tela mostrava as linhas e nada mais: "repasses divergentes" sem dizer
// CONTRA O QUE eles divergiram. Os três números do backend separam causas com
// providências opostas, e é essa distinção que faltava.
function leitura(e: ExecucaoConciliacao): { tom: string; texto: string } {
  if (e.erro) return { tom: "text-red-300", texto: `A execução falhou: ${e.erro}` }

  if (!e.repasses) {
    return {
      tom: "text-sky-300",
      texto:
        "Nenhum repasse no período. A conciliação compara repasses do marketplace " +
        "com títulos do OMIE — sem repasse, não há o que comparar.",
    }
  }

  if (!e.titulos_no_omie) {
    return {
      tom: "text-yellow-300",
      texto:
        "Nenhum título encontrado no OMIE no período. Enquanto eles não estiverem lá, " +
        "todo repasse aparece como divergente — não por diferença de valor, mas por " +
        "não haver contra o que comparar.",
    }
  }

  if (!e.repasses_com_nf) {
    return {
      tom: "text-yellow-300",
      texto:
        `${e.titulos_no_omie} título(s) no OMIE, mas nenhum repasse tem nota fiscal ligada ` +
        "do nosso lado. É o número da NF que casa os dois — sem ele, não há chave.",
    }
  }

  return {
    tom: e.conferidos > 0 ? "text-emerald-300" : "text-yellow-300",
    texto:
      `${e.conferidos} de ${e.repasses} repasse(s) conferiram com o OMIE. ` +
      `${e.sem_titulo ?? 0} não encontraram título correspondente.`,
  }
}

export default function ReconciliationDashboard() {
  const [filtros, setFiltros] = useState<FiltrosRegistros>({ page: 1 })
  const [busca, setBusca] = useState("")
  // Quanto tempo para trás conciliar.
  //
  // O backend concilia os últimos 30 dias quando ninguém diz o período, e
  // repasse mais velho que isso nunca vira registro. Não adiantava paginar: as
  // páginas antigas não existiam porque aqueles repasses jamais foram
  // conferidos.
  const [dias, setDias] = useState(30)
  const [processando, setProcessando] = useState(false)
  const [aviso, setAviso] = useState<string | null>(null)

  const { data, loading, error, reload } = useResource(
    () => fetchRegistros(filtros),
    [JSON.stringify(filtros)],
  )

  // O processamento é UM DE CADA VEZ (worker com concorrência 1). Sem saber
  // que já há uma execução na fila, o botão devolve "enfileirado" na primeira
  // e na quinta vez igualzinho — e as quatro extras só esperam para refazer o
  // que acabou de ser feito.
  const { data: filas } = useResource(fetchFilas)

  const jaRodando = ocupada(filas)

  function aplicar(mudanca: Partial<FiltrosRegistros>) {
    setFiltros((atual) => ({ ...atual, ...mudanca, page: 1 }))
  }

  // Espera o desfecho, em vez de dizer "enfileirado" e sumir.
  //
  // A conciliação roda em fila: o clique só devolvia um id de job, e o que ela
  // fez ficava numa linha de log. Aqui a tela acompanha o carimbo da última
  // execução até ele mudar, e então mostra o resultado.
  async function disparar() {
    const marco = data?.resumo?.execucao?.terminada_em ?? null

    setProcessando(true)
    setAviso(
      `Conciliando os últimos ${dias} dias de repasses...` +
        (dias > 30 ? " Períodos longos demoram: são mais títulos para ler do OMIE." : ""),
    )

    try {
      await processarConciliacao(janelaDe(dias))
    } catch (e) {
      setProcessando(false)
      setAviso(errorMessage(e, "Não foi possível disparar a conciliação"))
      return
    }

    for (let tentativa = 0; tentativa < ESPERA_MAXIMA; tentativa++) {
      await dorme(ESPERA_MS)

      let execucao: ExecucaoConciliacao | null | undefined

      try {
        execucao = (await fetchRegistros(filtros)).resumo.execucao
      } catch {
        continue // hipo da rede não cancela a espera
      }

      if (!execucao?.terminada_em || execucao.terminada_em === marco) continue

      setProcessando(false)
      setAviso(null)
      reload()

      return
    }

    setProcessando(false)
    setAviso(
      "A conciliação continua rodando em segundo plano. Atualize a página daqui a pouco.",
    )
  }

  const resumo = data?.resumo

  const stats = [
    { titulo: "Total Conciliado", valor: brl(resumo?.total_conciliado) },
    { titulo: "Divergências abertas", valor: String(resumo?.divergencias_abertas ?? 0) },
    { titulo: "Execuções hoje", valor: String(resumo?.execucoes_hoje ?? 0) },
    { titulo: "Última execução", valor: desde(resumo?.ultima_execucao) },
  ]

  return (
    <div className="space-y-6">
      <div className="flex flex-col lg:flex-row lg:items-center lg:justify-between gap-4">
        <div>
          <p className="text-zinc-400 text-sm">Conciliação Financeira</p>
          <h1 className="text-3xl font-bold tracking-tight mt-1">
            Central de Conciliação
          </h1>
        </div>

        <div className="flex flex-wrap gap-3">
          <select
            value={dias}
            onChange={(e) => setDias(Number(e.target.value))}
            className="bg-zinc-900 border border-zinc-800 rounded-xl px-4 py-3 text-sm outline-none focus:border-zinc-600"
            title="Quanto tempo para trás a próxima conciliação vai olhar"
          >
            {PERIODOS.map((p) => (
              <option key={p.valor} value={p.valor}>
                {p.rotulo}
              </option>
            ))}
          </select>

          <select
            value={filtros.plataforma ?? ""}
            onChange={(e) => aplicar({ plataforma: e.target.value || undefined })}
            className="bg-zinc-900 border border-zinc-800 rounded-xl px-4 py-3 text-sm outline-none focus:border-zinc-600"
          >
            <option value="">Todas plataformas</option>
            {PLATAFORMAS.map((p) => (
              <option key={p} value={p}>
                {rotulo(p)}
              </option>
            ))}
          </select>

          <button
            onClick={disparar}
            disabled={processando || jaRodando}
            title={
              jaRodando
                ? "Já existe uma execução na fila. Acompanhe em Processos."
                : undefined
            }
            className="flex items-center gap-2 bg-white text-black font-medium px-5 py-3 rounded-xl hover:opacity-90 transition disabled:opacity-50"
          >
            <RefreshCw size={15} className={processando || jaRodando ? "animate-spin" : ""} />
            {processando ? "Enfileirando..." : jaRodando ? "Já em execução" : "Processar Conciliação"}
          </button>
        </div>
      </div>

      {jaRodando && (
        <div className="bg-sky-500/10 border border-sky-500/20 rounded-2xl px-5 py-4 text-sm text-sky-200 flex flex-wrap items-center justify-between gap-3">
          <span>
            Já existe uma conciliação em andamento. Os números abaixo só mudam
            quando ela terminar.
          </span>

          <Link to="/processos" className="underline hover:text-sky-100 shrink-0">
            acompanhar
          </Link>
        </div>
      )}

      {/* Enquanto houver nota na fila, TODO número desta tela é provisório.
          Sem dizer isso, o cliente lê como resultado final — e "esperado R$
          300 contra recebido R$ 12.000" parece dinheiro sumido, quando é só o
          envio pela metade. */}
      {(resumo?.notas_a_enviar ?? 0) > 0 && (
        <div className="bg-sky-500/10 border border-sky-500/20 rounded-2xl px-5 py-4 text-sm text-sky-200 flex flex-wrap items-center justify-between gap-3">
          <span>
            <strong>Números provisórios.</strong> Ainda faltam{" "}
            {resumo?.notas_a_enviar} nota(s) para virar título no OMIE — até lá,
            os repasses são comparados contra uma parte dos títulos.
          </span>

          <Link
            to="/integracoes"
            className="underline hover:text-sky-100 shrink-0"
          >
            acompanhar o envio
          </Link>
        </div>
      )}

      {/* Espera tem fim; isto não tem. A nota emitida sem valor não vira
          título nunca, e o repasse que a contém é comparado sem ela — a
          diferença que aparece é dinheiro que entrou sem documento fiscal.
          Sem dizer isso, a divergência parece defeito do sistema. */}
      {(resumo?.notas_recusadas ?? 0) > 0 && (
        <div className="bg-amber-500/10 border border-amber-500/20 rounded-2xl px-5 py-4 text-sm text-amber-200 flex flex-wrap items-center justify-between gap-3">
          <span>
            <strong>{resumo?.notas_recusadas} nota(s) emitidas sem valor.</strong>{" "}
            Não viram título no OMIE, e o repasse que contiver uma delas é
            comparado sem ela — a diferença apontada é venda sem documento
            fiscal, e a correção é no Tiny.
          </span>

          <Link to="/integracoes" className="underline hover:text-amber-100 shrink-0">
            ver quais
          </Link>
        </div>
      )}

      {aviso && (
        <div className="bg-zinc-900 border border-zinc-800 rounded-2xl px-5 py-4 text-sm text-zinc-300 flex items-center justify-between gap-4">
          {aviso}
          <button onClick={reload} className="text-zinc-400 hover:text-white shrink-0">
            atualizar
          </button>
        </div>
      )}

      {/* O que a última execução fez. Sem isto, a tela mostrava as linhas e
          nada mais — "repasses divergentes" sem dizer contra o que eles
          divergiram, nem se houve contra o que comparar. */}
      {!aviso && resumo?.execucao && (
        <div className="bg-zinc-900 border border-zinc-800 rounded-2xl px-5 py-4 space-y-3">
          <div className="flex flex-wrap items-baseline justify-between gap-2">
            <p className={`text-sm ${leitura(resumo.execucao).tom}`}>
              {leitura(resumo.execucao).texto}
            </p>

            <span className="text-xs text-zinc-500 shrink-0">
              {resumo.execucao.periodo} · {desde(resumo.execucao.terminada_em)}
            </span>
          </div>

          <div className="grid grid-cols-2 lg:grid-cols-5 gap-3 text-xs">
            {[
              { rotulo: "Repasses", valor: resumo.execucao.repasses },
              { rotulo: "Títulos no OMIE", valor: resumo.execucao.titulos_no_omie },
              { rotulo: "Com nota fiscal", valor: resumo.execucao.repasses_com_nf },
              { rotulo: "Conferidos", valor: resumo.execucao.conferidos },
              { rotulo: "Sem título", valor: resumo.execucao.sem_titulo },
            ].map((item) => (
              <div key={item.rotulo}>
                <p className="text-zinc-500">{item.rotulo}</p>
                <p className="text-zinc-200 font-medium mt-0.5">{item.valor ?? "—"}</p>
              </div>
            ))}
          </div>
        </div>
      )}

      <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-4 gap-4">
        {stats.map((item) => (
          <div
            key={item.titulo}
            className="bg-zinc-900 border border-zinc-800 rounded-3xl p-5 shadow-xl"
          >
            <p className="text-sm text-zinc-400">{item.titulo}</p>
            <h2 className="text-2xl font-bold mt-3">{item.valor}</h2>
          </div>
        ))}
      </div>

      <div className="bg-zinc-900 border border-zinc-800 rounded-3xl overflow-hidden shadow-2xl">
        <div className="flex flex-col lg:flex-row lg:items-center lg:justify-between gap-4 p-5 border-b border-zinc-800">
          <div>
            <h2 className="text-lg font-semibold">Repasses conciliados</h2>
            <p className="text-zinc-400 text-sm mt-1">
              Cada linha compara um repasse da plataforma com os títulos do OMIE.
            </p>
          </div>

          <div className="flex flex-wrap gap-3">
            <form
              onSubmit={(e) => {
                e.preventDefault()
                aplicar({ busca: busca || undefined })
              }}
              className="relative"
            >
              <Search
                size={16}
                className="absolute left-4 top-1/2 -translate-y-1/2 text-zinc-500"
              />
              <input
                value={busca}
                onChange={(e) => setBusca(e.target.value)}
                placeholder="Buscar referência do repasse"
                className="bg-zinc-950 border border-zinc-800 rounded-xl pl-10 pr-4 py-3 text-sm min-w-[260px] outline-none focus:border-zinc-600"
              />
            </form>

            <select
              value={filtros.status ?? ""}
              onChange={(e) => aplicar({ status: e.target.value || undefined })}
              className="bg-zinc-950 border border-zinc-800 rounded-xl px-4 py-3 text-sm outline-none focus:border-zinc-600"
            >
              <option value="">Todos status</option>
              {STATUS.map((s) => (
                <option key={s} value={s}>
                  {rotulo(s)}
                </option>
              ))}
            </select>
          </div>
        </div>

        {loading ? (
          <Carregando />
        ) : error ? (
          <div className="p-5">
            <ErroAoCarregar mensagem={error} onRetry={reload} />
          </div>
        ) : data && data.items.length === 0 ? (
          <Vazio
            titulo="Nenhum repasse conciliado"
            descricao="Assim que houver repasses na janela e títulos correspondentes no OMIE, eles aparecem aqui."
          />
        ) : (
          <>
            <div className="overflow-x-auto">
              <table className="w-full min-w-[900px] text-sm">
                <thead className="bg-zinc-950/80 text-zinc-400 text-xs uppercase tracking-wide">
                  <tr>
                    <th className="text-left font-medium px-4 py-3">Status</th>
                    <th className="text-left font-medium px-4 py-3">Repasse</th>
                    <th className="text-left font-medium px-4 py-3">Plataforma</th>
                    <th className="text-right font-medium px-4 py-3">Esperado (OMIE)</th>
                    <th className="text-right font-medium px-4 py-3">Recebido</th>
                    <th className="text-right font-medium px-4 py-3">Diferença</th>
                    <th className="text-left font-medium px-4 py-3">Confiança</th>
                    <th className="text-left font-medium px-4 py-3">Data</th>
                  </tr>
                </thead>

                <tbody>
                  {data?.items.map((row) => {
                    // Sem o lado do OMIE não existe diferença: o que o backend
                    // devolve é o repasse inteiro. Mostrar isso na coluna
                    // "Diferença" — e ainda em VERDE, como se fosse ganho —
                    // fazia uma conciliação que não aconteceu parecer um saldo
                    // a favor. Diferença nunca é boa notícia.
                    const comparado = row.valor_esperado != null
                    const dif = Number(row.diferenca ?? 0)

                    return (
                      <Fragment key={row.id}>
                      <tr className="border-t border-zinc-800 hover:bg-zinc-800/30 transition">
                        <td className="px-4 py-3">
                          <Selo status={row.status} texto={rotulo(row.status)} />
                        </td>
                        <td className="px-4 py-3">
                          {/* O repasse é um BLOCO: o marketplace junta uma
                              centena de vendas numa transferência só. Sem
                              dizer quantas, doze linhas para milhares de
                              lançamentos parecem cobrir quase nada. */}
                          <span className="font-medium">
                            {row.vendas ? `${row.vendas} venda(s)` : "Repasse"}
                          </span>
                          <span
                            className="block text-xs text-zinc-500 mt-0.5"
                            title={row.referencia ?? undefined}
                          >
                            {row.pago_em ? `pago em ${dataHoraBR(row.pago_em)}` : "—"}
                          </span>
                        </td>
                        <td className="px-4 py-3 text-zinc-300">
                          {rotulo(row.plataforma)}
                        </td>
                        <td className="px-4 py-3 text-right">
                          {brl(row.valor_esperado)}
                        </td>
                        <td className="px-4 py-3 text-right">
                          {brl(row.valor_recebido)}
                        </td>
                        <td
                          className={`px-4 py-3 text-right font-medium ${
                            !comparado
                              ? "text-zinc-600"
                              : dif === 0
                                ? "text-emerald-400"
                                : "text-red-400"
                          }`}
                          title={
                            comparado
                              ? undefined
                              : "Não houve comparação: nenhum título do OMIE foi encontrado para este repasse."
                          }
                        >
                          {comparado ? brl(row.diferenca) : "—"}
                        </td>
                        <td className="px-4 py-3 text-zinc-400">
                          {Number(row.confianca).toFixed(0)}%
                        </td>
                        <td className="px-4 py-3 text-zinc-400">
                          {dataHoraBR(row.data)}
                        </td>
                      </tr>

                      {/* O motivo, por extenso.
                          Ele já era calculado e gravado, e a tela nunca o
                          mostrou: "por que este repasse não fechou?" só tinha
                          resposta no banco. É a frase que diz se falta nota,
                          se falta título, ou se a nota está dividida entre
                          repasses — três providências diferentes. */}
                      {row.observacao && (
                        <tr className="border-t border-zinc-900">
                          <td />
                          <td colSpan={7} className="px-4 pb-3 text-xs text-zinc-400 leading-relaxed">
                            {row.observacao}
                          </td>
                        </tr>
                      )}
                      </Fragment>
                    )
                  })}
                </tbody>
              </table>
            </div>

            {data && data.meta.total_pages > 1 && (
              <div className="flex items-center justify-between p-5 border-t border-zinc-800 text-sm">
                <span className="text-zinc-400">
                  {data.meta.total} registro(s) · página {data.meta.page} de{" "}
                  {data.meta.total_pages}
                </span>

                <div className="flex gap-2">
                  <button
                    disabled={data.meta.page <= 1}
                    onClick={() =>
                      setFiltros((f) => ({ ...f, page: (f.page ?? 1) - 1 }))
                    }
                    className="bg-zinc-800 hover:bg-zinc-700 disabled:opacity-40 px-4 py-2 rounded-lg transition"
                  >
                    Anterior
                  </button>
                  <button
                    disabled={data.meta.page >= data.meta.total_pages}
                    onClick={() =>
                      setFiltros((f) => ({ ...f, page: (f.page ?? 1) + 1 }))
                    }
                    className="bg-zinc-800 hover:bg-zinc-700 disabled:opacity-40 px-4 py-2 rounded-lg transition"
                  >
                    Próxima
                  </button>
                </div>
              </div>
            )}
          </>
        )}
      </div>
    </div>
  )
}
