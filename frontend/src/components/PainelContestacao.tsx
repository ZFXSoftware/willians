import { useState } from "react"
import { Check, Copy, ExternalLink, Info } from "lucide-react"

import {
  contestar,
  fetchContestacao,
  resolverDivergencia,
  type Divergencia,
} from "../api/divergencias"
import { errorMessage } from "../api/client"
import { useResource } from "../hooks/useResource"
import { Carregando, ErroAoCarregar } from "./Estados"

export default function PainelContestacao({
  divergencia,
  onFechar,
  onAtualizar,
}: {
  divergencia: Divergencia
  onFechar: () => void
  onAtualizar: (d: Divergencia) => void
}) {
  const { data, loading, error, reload } = useResource(
    () => fetchContestacao(divergencia.id),
    [divergencia.id],
  )

  const [protocolo, setProtocolo] = useState(divergencia.contestacao?.protocolo ?? "")
  const [salvando, setSalvando] = useState(false)
  const [aviso, setAviso] = useState<string | null>(null)

  async function registrar() {
    setSalvando(true)
    setAviso(null)

    try {
      onAtualizar(await contestar(divergencia.id, { protocolo }))
    } catch (e) {
      setAviso(errorMessage(e, "Não foi possível registrar"))
    } finally {
      setSalvando(false)
    }
  }

  async function resolver() {
    setSalvando(true)
    setAviso(null)

    try {
      onAtualizar(await resolverDivergencia(divergencia.id))
    } catch (e) {
      setAviso(errorMessage(e, "Não foi possível resolver"))
    } finally {
      setSalvando(false)
    }
  }

  return (
    <div className="mt-5 border-t border-zinc-800 pt-5">
      {loading ? (
        <Carregando texto="Montando a contestação..." />
      ) : error ? (
        <ErroAoCarregar mensagem={error} onRetry={reload} />
      ) : data ? (
        <div className="space-y-5">
          <div className="space-y-2">
            {data.campos.map((campo) => (
              <LinhaCopiavel key={campo.rotulo} rotulo={campo.rotulo} valor={campo.valor} />
            ))}
          </div>

          <div>
            <div className="flex items-center justify-between gap-3">
              <p className="text-xs uppercase tracking-wide text-zinc-500">
                Mensagem pronta
              </p>
              <BotaoCopiar texto={data.texto} rotulo="Copiar tudo" />
            </div>

            <pre className="mt-2 bg-zinc-950 border border-zinc-800 rounded-2xl px-4 py-3 text-xs text-zinc-300 whitespace-pre-wrap font-sans">
              {data.texto}
            </pre>
          </div>

          <div className="flex items-start gap-2 text-xs text-zinc-400 bg-white/5 border border-white/10 rounded-2xl px-4 py-3">
            <Info size={14} className="mt-0.5 shrink-0" />
            <span>
              As plataformas não abrem contestação por link com os dados
              preenchidos. O botão leva à venda no painel do vendedor; os
              valores acima são para colar lá.
              {!data.url_confirmada && (
                <>
                  {" "}
                  O endereço pode mudar — se cair no lugar errado, ajuste em
                  Configurações.
                </>
              )}
            </span>
          </div>

          <div className="flex items-center gap-3 flex-wrap">
            <a
              href={data.url}
              target="_blank"
              rel="noreferrer"
              className="flex items-center gap-2 bg-emerald-600 hover:bg-emerald-500 px-5 py-2.5 rounded-xl text-sm font-medium transition"
            >
              Abrir na plataforma
              <ExternalLink size={15} />
            </a>

            <input
              value={protocolo}
              onChange={(e) => setProtocolo(e.target.value)}
              placeholder="Protocolo devolvido pela plataforma"
              className="flex-1 min-w-[220px] bg-zinc-950 border border-zinc-800 focus:border-zinc-600 outline-none rounded-xl px-4 py-2.5 text-sm transition"
            />

            <button
              onClick={registrar}
              disabled={salvando}
              className="bg-zinc-800 hover:bg-zinc-700 disabled:opacity-40 px-5 py-2.5 rounded-xl text-sm transition"
            >
              Registrar contestação
            </button>

            {divergencia.status !== "resolved" && (
              <button
                onClick={resolver}
                disabled={salvando}
                className="text-sm text-zinc-400 hover:text-white transition"
              >
                Marcar como resolvida
              </button>
            )}

            <button
              onClick={onFechar}
              className="ml-auto text-sm text-zinc-500 hover:text-white transition"
            >
              fechar
            </button>
          </div>

          {divergencia.contestacao?.aberta_em && (
            <p className="text-xs text-zinc-500">
              Contestação registrada
              {divergencia.contestacao.protocolo &&
                ` sob o protocolo ${divergencia.contestacao.protocolo}`}
              {divergencia.contestacao.por && ` por ${divergencia.contestacao.por}`}.
            </p>
          )}

          {aviso && <p className="text-sm text-red-300">{aviso}</p>}
        </div>
      ) : null}
    </div>
  )
}

function LinhaCopiavel({ rotulo, valor }: { rotulo: string; valor: string }) {
  return (
    <div className="flex items-center justify-between gap-3 bg-zinc-950 border border-zinc-800 rounded-xl px-4 py-2.5">
      <span className="text-sm text-zinc-400 shrink-0">{rotulo}</span>

      <div className="flex items-center gap-2 min-w-0">
        <span className="text-sm font-medium truncate">{valor}</span>
        <BotaoCopiar texto={valor} />
      </div>
    </div>
  )
}

function BotaoCopiar({ texto, rotulo }: { texto: string; rotulo?: string }) {
  const [copiado, setCopiado] = useState(false)

  async function copiar() {
    await navigator.clipboard.writeText(texto)
    setCopiado(true)
    setTimeout(() => setCopiado(false), 1500)
  }

  return (
    <button
      onClick={copiar}
      title="Copiar"
      className="flex items-center gap-1.5 text-xs text-zinc-500 hover:text-white transition shrink-0"
    >
      {copiado ? <Check size={13} /> : <Copy size={13} />}
      {rotulo && <span>{copiado ? "Copiado" : rotulo}</span>}
    </button>
  )
}
