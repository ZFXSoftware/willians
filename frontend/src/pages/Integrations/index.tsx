import { useState } from "react"
import { Link, useSearchParams } from "react-router-dom"
import {
  Archive,
  Building2,
  CheckCircle2,
  DownloadCloud,
  FileText,
  KeyRound,
  Plug,
  RefreshCw,
  ShoppingBag,
  Trash2,
  XCircle,
} from "lucide-react"

import {
  arquivarConta,
  conectar,
  desconectar,
  enviarNotasAoOmie,
  fetchIntegracoes,
  importarNotas,
  removerConta,
  salvarCodigosOmie,
  sincronizar,
  type Integracao,
  type NotasFiscais,
  type ResultadoEnvioOmie,
  type ResultadoImportacao,
  type ResumoSincronizacao,
} from "../../api/integracoes"
import { errorMessage } from "../../api/client"
import { useResource } from "../../hooks/useResource"
import { dataHoraBR, desde, rotulo } from "../../lib/format"
import { Carregando, ErroAoCarregar, Selo, Vazio } from "../../components/Estados"
import { EscolhaDoOmie } from "../../components/EscolhaDoOmie"

const ICONES: Record<string, typeof ShoppingBag> = {
  mercado_livre: ShoppingBag,
  shopee: ShoppingBag,
  amazon: ShoppingBag,
  magalu: ShoppingBag,
  omie: Building2,
}

// A importação roda em fila, fora da requisição. Acompanhamos pelo carimbo de
// `ultima_sincronizacao`, que muda quando ela termina — mesmo sem trazer nada.
const ESPERA_MS = 5000

const ESPERA_MAXIMA = 48 // 4 minutos: o relatório do Mercado Pago pode demorar

const dorme = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms))

interface Nota {
  // "espera" é o marketplace ainda preparando o dado: nada quebrou e nada
  // chegou. Pintar de verde seria mentir; de vermelho, assustar à toa.
  tipo: "ok" | "espera" | "erro"
  texto: string
}

const CORES_DA_NOTA: Record<Nota["tipo"], string> = {
  ok: "bg-emerald-500/10 border-emerald-500/20 text-emerald-300",
  espera: "bg-sky-500/10 border-sky-500/20 text-sky-300",
  erro: "bg-red-500/10 border-red-500/20 text-red-300",
}

// Três desfechos, três frases.
//
// Antes eram dois — erro, ou sucesso —, e "o Mercado Livre ainda está gerando
// o relatório" caía no ramo do sucesso: "importação concluída — 0
// lançamento(s) no total", para uma importação que não aconteceu.
function notaDaSincronizacao(nome: string, conta: Integracao): Nota {
  if (conta.status_sincronizacao === "pendente") {
    return {
      tipo: "espera",
      texto:
        `${nome}: o marketplace ainda está preparando os dados do período. ` +
        "Nada falhou — tente de novo em alguns minutos.",
    }
  }

  if (conta.erro_de_sincronizacao) {
    return { tipo: "erro", texto: `${nome}: ${conta.erro_de_sincronizacao}` }
  }

  return {
    tipo: "ok",
    texto: `${nome}: importação concluída — ${conta.lancamentos} lançamento(s) no total.`,
  }
}

export default function Integrations() {
  const [params, setParams] = useSearchParams()
  // Chave em texto porque a ação tanto pode ser sobre uma conta (o id) quanto
  // sobre uma plataforma que ainda não tem conta nenhuma (o nome dela).
  const [acao, setAcao] = useState<string | null>(null)
  const [importando, setImportando] = useState<number | null>(null)
  const [nota, setNota] = useState<Nota | null>(null)

  const { data, loading, error, reload } = useResource(fetchIntegracoes)

  // Plataformas que o sistema já sabe integrar e para as quais ainda não existe
  // nenhuma conta. Sem isto a tela ficava sem saída: "Conectar" só aparecia
  // dentro do card de uma conta, e a primeira conta só nasce ao conectar.
  const jaTemConta = new Set(data?.items.map((i) => i.plataforma) ?? [])

  const disponiveis = (data?.plataformas_implementadas ?? []).filter((p) => !jaTemConta.has(p))

  // Retorno do OAuth: o backend devolve o navegador para cá com o resultado.
  const retornoStatus = params.get("status")
  const retornoMensagem = params.get("mensagem")

  function limparRetorno() {
    params.delete("status")
    params.delete("mensagem")
    params.delete("integracao")
    setParams(params, { replace: true })
  }

  // `conta` ausente é o caso normal da PRIMEIRA conexão: quem cria a conta é o
  // callback do OAuth, com o id real do vendedor na plataforma. Cadastrar uma
  // conta à mão antes disso só produziria um registro sem identificador, que o
  // callback depois duplicaria.
  async function iniciarConexao(plataforma: string, conta?: Integracao) {
    setAcao(conta ? String(conta.id) : plataforma)
    setNota(null)

    try {
      const { authorization_url } = await conectar(plataforma, conta?.id)
      window.location.href = authorization_url
    } catch (e) {
      setNota({ tipo: "erro", texto: errorMessage(e, "Não foi possível iniciar a conexão") })
      setAcao(null)
    }
  }

  async function remover(conta: Integracao) {
    setAcao(String(conta.id))
    setNota(null)

    try {
      await desconectar(conta.id)
      reload()
    } catch (e) {
      setNota({ tipo: "erro", texto: errorMessage(e, "Não foi possível desconectar") })
    } finally {
      setAcao(null)
    }
  }

  // Conta conectada por engano. Se nada foi importado, some de vez; se já
  // houver histórico, o backend recusa e a saída é arquivar.
  async function remover_de_vez(conta: Integracao) {
    setAcao(String(conta.id))
    setNota(null)

    try {
      await removerConta(conta.id)
      reload()
      setNota({ tipo: "ok", texto: `${conta.nome} foi removida.` })
    } catch (e) {
      setNota({ tipo: "erro", texto: errorMessage(e, "Não foi possível remover") })
    } finally {
      setAcao(null)
    }
  }

  async function arquivar(conta: Integracao) {
    setAcao(String(conta.id))
    setNota(null)

    try {
      await arquivarConta(conta.id)
      reload()
      setNota({
        tipo: "ok",
        texto: `${conta.nome} foi arquivada. O histórico dela continua no razão.`,
      })
    } catch (e) {
      setNota({ tipo: "erro", texto: errorMessage(e, "Não foi possível arquivar") })
    } finally {
      setAcao(null)
    }
  }

  async function importar(conta: Integracao) {
    setNota(null)
    setAcao(String(conta.id))

    const marco = conta.ultima_sincronizacao

    try {
      await sincronizar(conta.id)
    } catch (e) {
      setNota({ tipo: "erro", texto: errorMessage(e, "Não foi possível enfileirar a importação") })
      setAcao(null)
      return
    }

    setAcao(null)
    setImportando(conta.id)

    for (let tentativa = 0; tentativa < ESPERA_MAXIMA; tentativa++) {
      await dorme(ESPERA_MS)

      let atual: Integracao | undefined

      try {
        const { items } = await fetchIntegracoes()
        atual = items.find((i) => i.id === conta.id)
      } catch {
        continue // hipo da rede não cancela a espera
      }

      if (!atual || atual.ultima_sincronizacao === marco) continue

      setImportando(null)
      reload()

      setNota(notaDaSincronizacao(conta.nome, atual))

      return
    }

    setImportando(null)
    reload()

    setNota({
      tipo: "ok",
      texto:
        "A importação continua rodando em segundo plano. No Mercado Livre a primeira execução " +
        "espera o relatório ser gerado do outro lado. Atualize daqui a pouco.",
    })
  }

  return (
    <div className="space-y-6">
      <div className="flex flex-col lg:flex-row lg:items-center lg:justify-between gap-4">
        <div>
          <p className="text-zinc-400 text-sm">Conciliação Financeira</p>
          <h1 className="text-3xl font-bold tracking-tight mt-1">Integrações</h1>
        </div>

        <div className="flex items-center gap-3">
          <Link
            to="/configuracoes"
            className="flex items-center gap-2 bg-zinc-900 border border-zinc-800 hover:border-zinc-600 px-4 py-3 rounded-xl text-sm transition"
          >
            <KeyRound size={15} />
            Chaves de API
          </Link>

          <button
            onClick={reload}
            className="flex items-center gap-2 bg-zinc-900 border border-zinc-800 hover:border-zinc-600 px-4 py-3 rounded-xl text-sm transition"
          >
            <RefreshCw size={15} />
            Atualizar
          </button>
        </div>
      </div>

      {retornoStatus && (
        <div
          className={`rounded-2xl px-5 py-4 text-sm flex items-center justify-between gap-4 border ${
            retornoStatus === "ok"
              ? "bg-emerald-500/10 border-emerald-500/20 text-emerald-300"
              : "bg-red-500/10 border-red-500/20 text-red-300"
          }`}
        >
          <span>{retornoMensagem ?? (retornoStatus === "ok" ? "Conta conectada" : "Falha na conexão")}</span>
          <button onClick={limparRetorno} className="text-zinc-400 hover:text-white">
            fechar
          </button>
        </div>
      )}

      {nota && (
        <div
          className={`rounded-2xl px-5 py-4 text-sm flex items-center justify-between gap-4 border ${CORES_DA_NOTA[nota.tipo]}`}
        >
          <span>{nota.texto}</span>
          <button onClick={() => setNota(null)} className="text-zinc-400 hover:text-white shrink-0">
            fechar
          </button>
        </div>
      )}

      {loading ? (
        <Carregando />
      ) : error ? (
        <ErroAoCarregar mensagem={error} onRetry={reload} />
      ) : (
        <>
          <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
            <div className="bg-zinc-900 border border-zinc-800 rounded-3xl p-5 shadow-xl">
              <p className="text-sm text-zinc-400">Contas conectadas</p>
              <h2 className="text-2xl font-bold mt-3 text-emerald-400">
                {data?.resumo.conectadas ?? 0} / {data?.resumo.total ?? 0}
              </h2>
            </div>

            <div className="bg-zinc-900 border border-zinc-800 rounded-3xl p-5 shadow-xl">
              <p className="text-sm text-zinc-400">Lançamentos importados</p>
              <h2 className="text-2xl font-bold mt-3">
                {data?.items.reduce((t, i) => t + i.lancamentos, 0) ?? 0}
              </h2>
            </div>

            <div className="bg-zinc-900 border border-zinc-800 rounded-3xl p-5 shadow-xl">
              <p className="text-sm text-zinc-400">Precisam de atenção</p>
              <h2 className="text-2xl font-bold mt-3 text-red-400">
                {data?.resumo.precisam_atencao ?? 0}
              </h2>
            </div>
          </div>

          {data?.notas_fiscais && (
            <NotasFiscaisCard notas={data.notas_fiscais} aoTerminar={reload} />
          )}

          {disponiveis.length > 0 && (
            <div className="space-y-4">
              <div>
                <h2 className="text-lg font-semibold">Disponíveis para conectar</h2>
                <p className="text-sm text-zinc-400 mt-1">
                  A conta é criada na hora da autorização, com o identificador do vendedor
                  na própria plataforma. Não há nada para cadastrar antes.
                </p>
              </div>

              <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
                {disponiveis.map((plataforma) => {
                  const Icone = ICONES[plataforma] ?? ShoppingBag
                  const ocupado = acao === plataforma

                  return (
                    <div
                      key={plataforma}
                      className="bg-zinc-900 border border-dashed border-zinc-700 rounded-3xl p-6 flex items-center justify-between gap-4"
                    >
                      <div className="flex items-center gap-4 min-w-0">
                        <div className="w-12 h-12 rounded-2xl bg-white/5 border border-white/10 flex items-center justify-center text-zinc-400 shrink-0">
                          <Icone size={20} />
                        </div>

                        <div className="min-w-0">
                          <h3 className="font-semibold text-lg truncate">
                            {rotulo(plataforma)}
                          </h3>
                          <p className="text-sm text-zinc-500 mt-0.5">Nenhuma conta conectada</p>
                        </div>
                      </div>

                      <button
                        onClick={() => iniciarConexao(plataforma)}
                        disabled={ocupado}
                        className="flex items-center justify-center gap-2 bg-white text-black hover:opacity-90 transition px-4 py-3 rounded-xl text-sm font-medium disabled:opacity-50 shrink-0"
                      >
                        <Plug size={15} />
                        {ocupado ? "Redirecionando..." : "Conectar"}
                      </button>
                    </div>
                  )
                })}
              </div>
            </div>
          )}

          {data && data.items.length === 0 ? (
            <div className="bg-zinc-900 border border-zinc-800 rounded-3xl">
              <Vazio
                titulo="Nenhuma conta conectada ainda"
                descricao="Conecte um marketplace acima. Se as chaves de API dele ainda não estiverem preenchidas, comece por Chaves de API."
              />
            </div>
          ) : (
            <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
              {data?.items.map((conta) => {
                const Icone = ICONES[conta.plataforma] ?? ShoppingBag
                const ocupado = acao === String(conta.id)
                const ocupadoImportando = importando === conta.id

                return (
                  <div
                    key={conta.id}
                    className="bg-zinc-900 border border-zinc-800 rounded-3xl p-6 shadow-xl"
                  >
                    <div className="flex items-start justify-between gap-4">
                      <div className="flex items-center gap-4 min-w-0">
                        <div className="w-12 h-12 rounded-2xl bg-white/5 border border-white/10 flex items-center justify-center text-zinc-300 shrink-0">
                          <Icone size={20} />
                        </div>

                        <div className="min-w-0">
                          <h3 className="font-semibold text-lg truncate">
                            {conta.nome}
                          </h3>
                          <p className="text-sm text-zinc-400 mt-0.5">
                            {rotulo(conta.plataforma)}
                          </p>
                        </div>
                      </div>

                      <span className="inline-flex items-center gap-1.5 shrink-0">
                        {conta.conectada ? (
                          <CheckCircle2 size={13} className="text-emerald-400" />
                        ) : (
                          <XCircle size={13} className="text-zinc-500" />
                        )}
                        <Selo
                          status={conta.conectada ? "connected" : conta.credencial?.status ?? "pending"}
                          texto={
                            conta.conectada
                              ? "Conectada"
                              : conta.credencial
                                ? rotulo(conta.credencial.status)
                                : "Não conectada"
                          }
                        />
                      </span>
                    </div>

                    <div className="mt-6 space-y-3 border-t border-zinc-800 pt-5 text-sm">
                      <div className="flex items-center justify-between gap-4">
                        <span className="text-zinc-400">Identificador</span>
                        <span className="font-medium truncate">
                          {conta.external_id ?? "—"}
                        </span>
                      </div>

                      <div className="flex items-center justify-between gap-4">
                        <span className="text-zinc-400">Lançamentos</span>
                        <span className="font-medium">{conta.lancamentos}</span>
                      </div>

                      <div className="flex items-center justify-between gap-4">
                        <span className="text-zinc-400">Última importação</span>
                        <span className="font-medium">
                          {ocupadoImportando ? "agora" : desde(conta.ultima_sincronizacao)}
                        </span>
                      </div>

                      <div className="flex items-center justify-between gap-4">
                        <span className="text-zinc-400">Último lançamento</span>
                        <span className="font-medium">
                          {desde(conta.ultimo_lancamento)}
                        </span>
                      </div>

                      {conta.credencial?.expira_em && (
                        <div className="flex items-center justify-between gap-4">
                          <span className="text-zinc-400">Token expira</span>
                          <span className="font-medium">
                            {dataHoraBR(conta.credencial.expira_em)}
                          </span>
                        </div>
                      )}
                    </div>

                    {conta.credencial?.erro && (
                      <p className="mt-4 text-xs text-red-400 bg-red-500/10 border border-red-500/20 rounded-xl px-3 py-2">
                        {conta.credencial.erro}
                      </p>
                    )}

                    <ResumoDaSincronizacao resumo={conta.resumo_sincronizacao} />

                    {conta.erro_de_sincronizacao &&
                      (conta.status_sincronizacao === "pendente" ? (
                        <p className="mt-4 text-xs text-sky-300 bg-sky-500/10 border border-sky-500/20 rounded-xl px-3 py-2">
                          Aguardando o marketplace: {conta.erro_de_sincronizacao}
                        </p>
                      ) : (
                        <p className="mt-4 text-xs text-red-400 bg-red-500/10 border border-red-500/20 rounded-xl px-3 py-2">
                          Última importação falhou: {conta.erro_de_sincronizacao}
                        </p>
                      ))}

                    <CodigosDoOmie conta={conta} aoSalvar={reload} />

                    <div className="mt-6 flex gap-2">
                      {!conta.integracao_disponivel ? (
                        <p className="text-sm text-zinc-500">
                          Integração com {rotulo(conta.plataforma)} ainda não
                          implementada.
                        </p>
                      ) : conta.conectada ? (
                        <>
                          <button
                            onClick={() => importar(conta)}
                            disabled={ocupado || ocupadoImportando}
                            className="flex-1 flex items-center justify-center gap-2 bg-white text-black hover:opacity-90 transition px-4 py-3 rounded-xl text-sm font-medium disabled:opacity-50"
                          >
                            <DownloadCloud
                              size={15}
                              className={ocupadoImportando ? "animate-pulse" : undefined}
                            />
                            {ocupadoImportando ? "Importando..." : "Sincronizar agora"}
                          </button>

                          <button
                            onClick={() => remover(conta)}
                            disabled={ocupado || ocupadoImportando}
                            className="bg-zinc-800 hover:bg-zinc-700 transition px-4 py-3 rounded-xl text-sm font-medium disabled:opacity-50"
                          >
                            {ocupado ? "Desconectando..." : "Desconectar"}
                          </button>
                        </>
                      ) : (
                        <>
                          <button
                            onClick={() => iniciarConexao(conta.plataforma, conta)}
                            disabled={ocupado}
                            className="flex-1 flex items-center justify-center gap-2 bg-white text-black hover:opacity-90 transition px-4 py-3 rounded-xl text-sm font-medium disabled:opacity-50"
                          >
                            <Plug size={15} />
                            {ocupado ? "Redirecionando..." : "Conectar"}
                          </button>

                          {/* Conta desconectada e sem nada importado é quase
                              sempre engano de OAuth: pode sumir. Com histórico,
                              apagar levaria pedidos e lançamentos junto — aí a
                              saída é arquivar. */}
                          {conta.lancamentos === 0 ? (
                            <button
                              onClick={() => remover_de_vez(conta)}
                              disabled={ocupado}
                              title="Remover esta conta da empresa"
                              className="flex items-center justify-center gap-2 bg-zinc-800 hover:bg-red-500/20 hover:text-red-300 transition px-4 py-3 rounded-xl text-sm font-medium disabled:opacity-50"
                            >
                              <Trash2 size={15} />
                              Remover
                            </button>
                          ) : (
                            <button
                              onClick={() => arquivar(conta)}
                              disabled={ocupado}
                              title="Tira da operação; o histórico continua no razão"
                              className="flex items-center justify-center gap-2 bg-zinc-800 hover:bg-zinc-700 transition px-4 py-3 rounded-xl text-sm font-medium disabled:opacity-50"
                            >
                              <Archive size={15} />
                              Arquivar
                            </button>
                          )}
                        </>
                      )}
                    </div>
                  </div>
                )
              })}
            </div>
          )}
        </>
      )}
    </div>
  )
}

// Os códigos do OMIE desta conta de marketplace.
//
// A tela da empresa tem UM campo de cliente/fornecedor e UM de conta corrente.
// Quem vende no Mercado Livre, na Amazon e na Shopee precisa de três: cada
// marketplace é um cliente diferente no OMIE e cai numa conta corrente
// diferente. A hierarquia já existia no backend; faltava onde preencher.
function CodigosDoOmie({
  conta,
  aoSalvar,
}: {
  conta: Integracao
  aoSalvar: () => void
}) {
  const [aberto, setAberto] = useState(false)
  const [cliente, setCliente] = useState(conta.omie?.cliente_fornecedor_id ?? "")
  const [contaCorrente, setContaCorrente] = useState(
    conta.omie?.conta_corrente_id ?? "",
  )
  const [salvando, setSalvando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)

  if (!conta.integracao_disponivel || !conta.omie) return null

  // "herdado" e não "faltando": campo em branco aqui pode estar usando o
  // padrão da empresa e funcionando. Alarme onde não há problema ensina a
  // ignorar alarme.
  function resumo(chave: "cliente_fornecedor_id" | "conta_corrente_id") {
    const efetivo = conta.omie.efetivo[chave]
    const origem = conta.omie.origem[chave]

    if (!efetivo) return "não definido"

    return origem === "platform_account"
      ? `${efetivo} (desta conta)`
      : `${efetivo} (padrão da empresa)`
  }

  async function salvar() {
    setSalvando(true)
    setErro(null)

    try {
      await salvarCodigosOmie(conta.id, {
        cliente_fornecedor_id: cliente,
        conta_corrente_id: contaCorrente,
      })

      aoSalvar()
      setAberto(false)
    } catch (e) {
      setErro(errorMessage(e, "Não foi possível salvar os códigos"))
    } finally {
      setSalvando(false)
    }
  }

  return (
    <div className="mt-4 border-t border-zinc-800 pt-4">
      <button
        onClick={() => setAberto(!aberto)}
        className="text-xs text-zinc-400 hover:text-zinc-200 transition"
      >
        {/* Nomeia o marketplace: é assim que a pessoa pensa o problema —
            "cada marketplace tem um cliente diferente no OMIE". */}
        Códigos do OMIE para {rotulo(conta.plataforma)} {aberto ? "▲" : "▼"}
      </button>

      {!aberto && (
        <p className="text-xs text-zinc-500 mt-2">
          Cliente {resumo("cliente_fornecedor_id")} · Conta corrente{" "}
          {resumo("conta_corrente_id")}
        </p>
      )}

      {aberto && (
        <div className="mt-3 space-y-3">
          <p className="text-xs text-zinc-500">
            Em branco usa o padrão da empresa. Rode{" "}
            <code className="text-zinc-400">rails omie:opcoes</code> para ver os
            códigos disponíveis no seu OMIE.
          </p>

          <div>
            <label className="text-xs text-zinc-400">Cliente/fornecedor</label>
            <div className="mt-1">
              <EscolhaDoOmie
                tipo="clientes"
                valor={cliente}
                placeholder={String(conta.omie.efetivo.cliente_fornecedor_id ?? "")}
                aoEscolher={setCliente}
              />
            </div>
          </div>

          <div>
            <label className="text-xs text-zinc-400">Conta corrente</label>
            <div className="mt-1">
              <EscolhaDoOmie
                tipo="contas_correntes"
                valor={contaCorrente}
                placeholder={String(conta.omie.efetivo.conta_corrente_id ?? "")}
                aoEscolher={setContaCorrente}
              />
            </div>
          </div>

          {erro && <p className="text-xs text-red-400">{erro}</p>}

          <button
            onClick={salvar}
            disabled={salvando}
            className="bg-white text-black hover:opacity-90 transition px-4 py-2 rounded-xl text-sm font-medium disabled:opacity-50"
          >
            {salvando ? "Salvando..." : "Salvar"}
          </button>
        </div>
      )}
    </div>
  )
}

// O que a última importação fez, em uma frase.
//
// Zero nota lida NÃO é erro nem sucesso: costuma ser janela sem faturamento, e
// merece frase própria. E `sem_plataforma` é o caso silencioso que mais custa
// caro — a nota foi lida e descartada porque a empresa tem mais de um
// marketplace e não dá para saber de qual ela é.
function notaDaImportacao(r: ResultadoImportacao): Nota {
  if (r.erro) return { tipo: "erro", texto: r.erro }

  if (!r.lidas) {
    return {
      tipo: "espera",
      texto: `Nenhuma nota encontrada no período${r.periodo ? ` (${r.periodo})` : ""}.`,
    }
  }

  const partes = [
    `${r.lidas} nota(s) lida(s)`,
    `${r.criadas ?? 0} nova(s)`,
    `${r.atualizadas ?? 0} atualizada(s)`,
  ]

  if (r.pedidos_criados) partes.push(`${r.pedidos_criados} pedido(s) criado(s)`)

  if (r.sem_plataforma) {
    return {
      tipo: "erro",
      texto:
        `${partes.join(", ")}. Mas ${r.sem_plataforma} ficaram de fora: a empresa tem ` +
        "mais de um marketplace e a nota do Tiny não diz de qual ela é.",
    }
  }

  return { tipo: "ok", texto: `${partes.join(", ")}.` }
}

// As notas fiscais do Tiny.
//
// Não são uma conta de marketplace, mas pertencem a esta tela: respondem à
// mesma pergunta que ela faz — o que já entrou e o que falta entrar. E isto
// era uma tarefa de linha de comando, o que só funciona para quem tem acesso
// ao servidor.
function NotasFiscaisCard({
  notas,
  aoTerminar,
}: {
  notas: NotasFiscais
  aoTerminar: () => void
}) {
  const [importando, setImportando] = useState(false)
  const [aviso, setAviso] = useState<Nota | null>(null)

  // "Enfileirado" não é resposta: é igual para sucesso e para falha.
  //
  // O backend grava o desfecho na empresa quando a fila termina, e aqui a
  // tela espera esse carimbo mudar — o mesmo caminho do "Sincronizar agora".
  async function importar() {
    const marco = notas.ultimo_resultado?.em ?? null

    setImportando(true)
    setAviso({
      tipo: "espera",
      texto: "Importação em andamento. São milhares de notas em páginas de 100.",
    })

    try {
      await importarNotas(90)
    } catch (e) {
      setImportando(false)
      setAviso({ tipo: "erro", texto: errorMessage(e, "Não foi possível iniciar a importação") })
      return
    }

    for (let tentativa = 0; tentativa < ESPERA_MAXIMA; tentativa++) {
      await dorme(ESPERA_MS)

      let atual: NotasFiscais | undefined

      try {
        atual = (await fetchIntegracoes()).notas_fiscais
      } catch {
        continue // hipo da rede não cancela a espera
      }

      if (!atual?.ultimo_resultado || atual.ultimo_resultado.em === marco) continue

      setImportando(false)
      setAviso(notaDaImportacao(atual.ultimo_resultado))
      aoTerminar()

      return
    }

    setImportando(false)
    aoTerminar()

    setAviso({
      tipo: "espera",
      texto:
        "A importação continua rodando em segundo plano — 4 mil notas levam alguns " +
        "minutos. Atualize a página daqui a pouco.",
    })
  }

  return (
    <div className="bg-zinc-900 border border-zinc-800 rounded-3xl p-6">
      <div className="flex flex-col lg:flex-row lg:items-center lg:justify-between gap-4">
        <div>
          <h2 className="text-lg font-semibold flex items-center gap-2">
            <FileText size={17} />
            Notas fiscais (Tiny)
          </h2>
          <p className="text-sm text-zinc-400 mt-1 max-w-2xl">
            É a nota que traz o número do pedido do marketplace e o número da NF
            — a chave que liga o repasse ao título do OMIE. Importar aqui grava
            só no Willians; enviar ao OMIE é outro passo.
          </p>
        </div>

        {notas.configurado ? (
          <div className="flex flex-wrap gap-2 shrink-0">
            <button
              onClick={importar}
              disabled={importando}
              className="flex items-center justify-center gap-2 bg-white text-black hover:opacity-90 transition px-5 py-3 rounded-xl text-sm font-medium disabled:opacity-50"
            >
              <DownloadCloud size={15} className={importando ? "animate-pulse" : undefined} />
              {importando ? "Enfileirando..." : "Importar do Tiny"}
            </button>

            <EnvioAoOmie
              pendentes={notas.total - notas.enviadas_ao_omie}
              aoTerminar={aoTerminar}
            />
          </div>
        ) : (
          <Link
            to="/configuracoes"
            className="flex items-center gap-2 bg-zinc-800 hover:bg-zinc-700 px-5 py-3 rounded-xl text-sm transition shrink-0"
          >
            <KeyRound size={15} />
            Configurar o Tiny
          </Link>
        )}
      </div>

      <div className="mt-5 grid grid-cols-2 lg:grid-cols-4 gap-4 text-sm">
        <div>
          <p className="text-zinc-500 text-xs">Notas importadas</p>
          <p className="font-medium mt-1">{notas.total}</p>
        </div>
        <div>
          <p className="text-zinc-500 text-xs">Com pedido</p>
          {/* Sem pedido a corrente não fecha: é o número que decide se a
              conciliação vai ter como casar com o marketplace. */}
          <p className="font-medium mt-1">{notas.com_pedido}</p>
        </div>
        <div>
          <p className="text-zinc-500 text-xs">Enviadas ao OMIE</p>
          <p className="font-medium mt-1">{notas.enviadas_ao_omie}</p>
        </div>
        <div>
          <p className="text-zinc-500 text-xs">Última importação</p>
          <p className="font-medium mt-1">
            {notas.ultima_importacao ? desde(notas.ultima_importacao) : "nunca"}
          </p>
        </div>
      </div>

      {/* Sem o `?? `, o desfecho sumia ao recarregar a página e a pessoa
          ficava sem saber o que a última importação fez. */}
      {(() => {
        const mostrar =
          aviso ?? (notas.ultimo_resultado ? notaDaImportacao(notas.ultimo_resultado) : null)

        if (!mostrar) return null

        return (
          <div
            className={`mt-4 rounded-2xl px-4 py-3 text-sm border ${CORES_DA_NOTA[mostrar.tipo]}`}
          >
            {mostrar.texto}
          </div>
        )
      })()}
    </div>
  )
}

// Envia as notas ao OMIE como títulos a receber.
//
// Este passo só existia como tarefa de linha de comando, o que não se sustenta
// com vários clientes. Mas ele grava na CONTABILIDADE de alguém, então o botão
// não pode ser um botão comum: simula primeiro, mostra o que aconteceria, e só
// então oferece o envio — uma nota, depois o lote.
function EnvioAoOmie({
  pendentes,
  aoTerminar,
}: {
  pendentes: number
  aoTerminar: () => void
}) {
  const [ocupado, setOcupado] = useState(false)
  const [previa, setPrevia] = useState<ResultadoEnvioOmie | null>(null)
  const [erro, setErro] = useState<string | null>(null)

  async function executar(opcoes: { aplicar?: boolean; limite?: number }) {
    setOcupado(true)
    setErro(null)

    try {
      const resultado = await enviarNotasAoOmie(opcoes)

      setPrevia(resultado)

      // Recarrega só quando ALGO mudou. Simulação não muda número nenhum, e
      // pedir recarga à toa é trabalho para o servidor e piscada para o
      // usuário.
      if (resultado.enviadas > 0) aoTerminar()
    } catch (e) {
      setErro(errorMessage(e, "Não foi possível falar com o OMIE"))
    } finally {
      setOcupado(false)
    }
  }

  if (pendentes <= 0 && !previa) {
    return (
      <span className="flex items-center px-4 py-3 text-sm text-zinc-500">
        Nada pendente para o OMIE
      </span>
    )
  }

  return (
    <>
      <button
        onClick={() => executar({})}
        disabled={ocupado}
        className="flex items-center justify-center gap-2 bg-zinc-800 hover:bg-zinc-700 transition px-5 py-3 rounded-xl text-sm font-medium disabled:opacity-50"
        title="Simula primeiro: nada é gravado no OMIE"
      >
        <Building2 size={15} />
        {ocupado ? "Consultando..." : `Enviar ao OMIE (${pendentes})`}
      </button>

      {(previa || erro) && (
        <div className="w-full mt-3 bg-zinc-950 border border-zinc-800 rounded-2xl p-4 text-sm space-y-3">
          {erro && <p className="text-red-400">{erro}</p>}

          {previa && (
            <>
              <p className={previa.simulado ? "text-sky-300" : "text-emerald-300"}>
                {previa.simulado
                  ? `Simulação: ${previa.previstas} título(s) seriam criados no OMIE.`
                  : `${previa.enviadas} título(s) criados no OMIE.`}
              </p>

              {previa.sem_comprador > 0 && (
                <p className="text-yellow-300 text-xs">
                  {previa.sem_comprador} nota(s) sem CPF/CNPJ do comprador ficam de
                  fora — cadastro sem identificação é pior do que nota faltando.
                </p>
              )}

              {previa.amostra && previa.amostra.length > 0 && (
                <div className="text-xs text-zinc-400 space-y-1">
                  {previa.amostra.map((item) => (
                    <p key={item.nf}>
                      NF {item.nf} · {item.comprador} · R$ {item.valor}
                    </p>
                  ))}
                </div>
              )}

              {previa.aviso && <p className="text-yellow-300 text-xs">{previa.aviso}</p>}

              {previa.motivo_da_simulacao === "escrita_bloqueada" && (
                <p className="text-xs text-zinc-500">
                  A gravação no OMIE está travada neste servidor
                  (OMIE_ALLOW_WRITES). Nada foi gravado.
                </p>
              )}

              {/* Uma nota antes do lote. Conferir um título no OMIE custa um
                  minuto; desfazer quatro mil custa um dia. */}
              {previa.simulado && previa.previstas > 0 && !previa.motivo_da_simulacao && (
                <div className="flex flex-wrap gap-2 pt-1">
                  <button
                    onClick={() => executar({ aplicar: true, limite: 1 })}
                    disabled={ocupado}
                    className="bg-white text-black hover:opacity-90 transition px-4 py-2 rounded-xl text-sm font-medium disabled:opacity-50"
                  >
                    Enviar 1 para conferir
                  </button>

                  <button
                    onClick={() => executar({ aplicar: true })}
                    disabled={ocupado}
                    className="bg-zinc-800 hover:bg-zinc-700 transition px-4 py-2 rounded-xl text-sm disabled:opacity-50"
                  >
                    Enviar todas ({previa.previstas})
                  </button>
                </div>
              )}
            </>
          )}
        </div>
      )}
    </>
  )
}

// O que a última sincronização fez.
//
// Ela roda em FILA: a tela dispara e não recebe resposta nenhuma. Sem isto,
// "quantos lançamentos entraram" e "quantos pedidos o marketplace tem" só
// existiam no log do servidor — e essas perguntas são rotina, não diagnóstico.
function ResumoDaSincronizacao({ resumo }: { resumo: ResumoSincronizacao | null }) {
  if (!resumo || resumo.status !== "ok") return null

  const linhas = [
    { rotulo: "Lançamentos novos", valor: resumo.novos },
    { rotulo: "Já conhecidos", valor: resumo.repetidos },
    // O número que separa "a conta vende pouco" de "conectamos a conta errada":
    // vem da API de PEDIDOS do marketplace, independente do extrato do dinheiro.
    { rotulo: "Pedidos no período", valor: resumo.pedidos },
    { rotulo: "Ligados ao pedido", valor: resumo.lancamentos_ligados },
    { rotulo: "Repasses fechados", valor: resumo.repasses_novos },
  ].filter((l) => l.valor !== undefined && l.valor !== null)

  if (linhas.length === 0 && !resumo.vinculo_erro) return null

  return (
    <div className="mt-4 bg-zinc-950 border border-zinc-800 rounded-xl px-3 py-2">
      <p className="text-xs text-zinc-500">
        Última sincronização {resumo.periodo ? `(${resumo.periodo})` : ""}
      </p>

      {/* Os lançamentos entraram, mas sem os pedidos nada liga o dinheiro à
          nota fiscal — e a conciliação contra o OMIE fica sem chave. Isso
          precisa aparecer, mesmo com a importação tendo funcionado. */}
      {resumo.vinculo_erro && (
        <p className="mt-2 text-xs text-yellow-300 bg-yellow-500/10 border border-yellow-500/20 rounded-lg px-2 py-1.5">
          Os lançamentos entraram, mas não foi possível ligá-los aos pedidos:{" "}
          {resumo.vinculo_erro}
        </p>
      )}

      <div className="mt-2 grid grid-cols-2 gap-x-4 gap-y-1">
        {linhas.map((linha) => (
          <p key={linha.rotulo} className="text-xs flex justify-between gap-2">
            <span className="text-zinc-500">{linha.rotulo}</span>
            <span className="text-zinc-300 font-medium">{linha.valor}</span>
          </p>
        ))}
      </div>
    </div>
  )
}
