import { useState } from "react"
import { Link, useSearchParams } from "react-router-dom"
import {
  Archive,
  Building2,
  CheckCircle2,
  DownloadCloud,
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
  fetchIntegracoes,
  removerConta,
  salvarCodigosOmie,
  sincronizar,
  type Integracao,
} from "../../api/integracoes"
import { errorMessage } from "../../api/client"
import { useResource } from "../../hooks/useResource"
import { dataHoraBR, desde, rotulo } from "../../lib/format"
import { Carregando, ErroAoCarregar, Selo, Vazio } from "../../components/Estados"

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
        Códigos do OMIE desta conta {aberto ? "▲" : "▼"}
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
            <input
              value={cliente}
              onChange={(e) => setCliente(e.target.value)}
              placeholder={String(conta.omie.efetivo.cliente_fornecedor_id ?? "")}
              className="mt-1 w-full bg-zinc-950 border border-zinc-800 rounded-xl px-3 py-2 text-sm"
            />
          </div>

          <div>
            <label className="text-xs text-zinc-400">Conta corrente</label>
            <input
              value={contaCorrente}
              onChange={(e) => setContaCorrente(e.target.value)}
              placeholder={String(conta.omie.efetivo.conta_corrente_id ?? "")}
              className="mt-1 w-full bg-zinc-950 border border-zinc-800 rounded-xl px-3 py-2 text-sm"
            />
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
