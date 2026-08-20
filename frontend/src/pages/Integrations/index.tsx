import { useState } from "react"
import { Link, useSearchParams } from "react-router-dom"
import {
  Building2,
  CheckCircle2,
  KeyRound,
  Plug,
  RefreshCw,
  ShoppingBag,
  XCircle,
} from "lucide-react"

import {
  conectar,
  desconectar,
  fetchIntegracoes,
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

export default function Integrations() {
  const [params, setParams] = useSearchParams()
  const [acao, setAcao] = useState<number | null>(null)
  const [aviso, setAviso] = useState<string | null>(null)

  const { data, loading, error, reload } = useResource(fetchIntegracoes)

  // Retorno do OAuth: o backend devolve o navegador para cá com o resultado.
  const retornoStatus = params.get("status")
  const retornoMensagem = params.get("mensagem")

  function limparRetorno() {
    params.delete("status")
    params.delete("mensagem")
    params.delete("integracao")
    setParams(params, { replace: true })
  }

  async function iniciarConexao(conta: Integracao) {
    setAcao(conta.id)
    setAviso(null)

    try {
      const { authorization_url } = await conectar(conta.plataforma, conta.id)
      window.location.href = authorization_url
    } catch (e) {
      setAviso(errorMessage(e, "Não foi possível iniciar a conexão"))
      setAcao(null)
    }
  }

  async function remover(conta: Integracao) {
    setAcao(conta.id)
    setAviso(null)

    try {
      await desconectar(conta.id)
      reload()
    } catch (e) {
      setAviso(errorMessage(e, "Não foi possível desconectar"))
    } finally {
      setAcao(null)
    }
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

      {aviso && (
        <div className="bg-red-500/10 border border-red-500/20 rounded-2xl px-5 py-4 text-sm text-red-300">
          {aviso}
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

          {data && data.items.length === 0 ? (
            <div className="bg-zinc-900 border border-zinc-800 rounded-3xl">
              <Vazio
                titulo="Nenhuma conta cadastrada"
                descricao="Cadastre uma conta de marketplace para começar a importar vendas e repasses."
              />
            </div>
          ) : (
            <div className="grid grid-cols-1 lg:grid-cols-2 gap-4">
              {data?.items.map((conta) => {
                const Icone = ICONES[conta.plataforma] ?? ShoppingBag
                const ocupado = acao === conta.id

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
                          {desde(conta.ultima_sincronizacao)}
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

                    <div className="mt-6 flex gap-2">
                      {!conta.integracao_disponivel ? (
                        <p className="text-sm text-zinc-500">
                          Integração com {rotulo(conta.plataforma)} ainda não
                          implementada.
                        </p>
                      ) : conta.conectada ? (
                        <button
                          onClick={() => remover(conta)}
                          disabled={ocupado}
                          className="flex-1 bg-zinc-800 hover:bg-zinc-700 transition px-4 py-3 rounded-xl text-sm font-medium disabled:opacity-50"
                        >
                          {ocupado ? "Desconectando..." : "Desconectar"}
                        </button>
                      ) : (
                        <button
                          onClick={() => iniciarConexao(conta)}
                          disabled={ocupado}
                          className="flex-1 flex items-center justify-center gap-2 bg-white text-black hover:opacity-90 transition px-4 py-3 rounded-xl text-sm font-medium disabled:opacity-50"
                        >
                          <Plug size={15} />
                          {ocupado ? "Redirecionando..." : "Conectar"}
                        </button>
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
