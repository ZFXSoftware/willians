import { useState } from "react"
import { ArrowLeftRight, CheckCircle2, FileText, RefreshCw, Undo2 } from "lucide-react"

import {
  fetchDevolucoes,
  rastrearDevolucoes,
  type Devolucao,
  type StatusDevolucao,
} from "../../api/devolucoes"
import { errorMessage } from "../../api/client"
import { useResource } from "../../hooks/useResource"
import { brl, dataBR, rotulo } from "../../lib/format"
import { Carregando, ErroAoCarregar, Vazio } from "../../components/Estados"

// A ordem é a do ciclo: cada etapa só é alcançada quando a anterior fechou.
const ETAPAS: Array<{ chave: StatusDevolucao; titulo: string }> = [
  { chave: "sem_origem", titulo: "Sem origem" },
  { chave: "aberta", titulo: "Aberta" },
  { chave: "aguardando_nota", titulo: "Aguardando NF" },
  { chave: "concluida", titulo: "Concluída" },
]

const TONS: Record<StatusDevolucao, string> = {
  sem_origem: "bg-red-500/15 text-red-400 border-red-500/20",
  aberta: "bg-yellow-500/15 text-yellow-400 border-yellow-500/20",
  com_origem: "bg-sky-500/15 text-sky-400 border-sky-500/20",
  aguardando_nota: "bg-sky-500/15 text-sky-400 border-sky-500/20",
  concluida: "bg-emerald-500/15 text-emerald-400 border-emerald-500/20",
}

const TIPOS: Record<string, string> = {
  devolucao: "Devolução",
  disputa: "Disputa",
  chargeback: "Chargeback",
}

export default function Returns() {
  const [filtro, setFiltro] = useState<StatusDevolucao | "">("")
  const [rastreando, setRastreando] = useState(false)
  const [aviso, setAviso] = useState<string | null>(null)

  const { data, loading, error, reload } = useResource(
    () => fetchDevolucoes(filtro),
    [filtro],
  )

  async function rastrear() {
    setRastreando(true)
    setAviso(null)

    try {
      await rastrearDevolucoes()
      reload()
    } catch (e) {
      setAviso(errorMessage(e, "Não foi possível rastrear as devoluções"))
    } finally {
      setRastreando(false)
    }
  }

  const porStatus = data?.resumo.por_status ?? {}

  return (
    <div className="space-y-6">
      <div className="flex flex-col lg:flex-row lg:items-center lg:justify-between gap-4">
        <div>
          <p className="text-zinc-400 text-sm">Conciliação Financeira</p>
          <h1 className="text-3xl font-bold tracking-tight mt-1">Devoluções e disputas</h1>
          <p className="text-sm text-zinc-400 mt-2 max-w-2xl">
            Cada estorno é seguido da abertura até o ajuste final: o pedido de
            origem, a nota fiscal da venda e a nota de devolução.
          </p>
        </div>

        <button
          onClick={rastrear}
          disabled={rastreando}
          className="flex items-center gap-2 bg-emerald-600 hover:bg-emerald-500 disabled:opacity-40 px-5 py-3 rounded-xl text-sm font-medium transition shrink-0"
        >
          <RefreshCw size={15} className={rastreando ? "animate-spin" : ""} />
          {rastreando ? "Rastreando..." : "Rastrear agora"}
        </button>
      </div>

      {aviso && (
        <div className="bg-red-500/10 border border-red-500/20 rounded-2xl px-5 py-4 text-sm text-red-300">
          {aviso}
        </div>
      )}

      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        {ETAPAS.map((etapa) => (
          <button
            key={etapa.chave}
            onClick={() => setFiltro(filtro === etapa.chave ? "" : etapa.chave)}
            className={`bg-zinc-900 border rounded-3xl p-5 shadow-xl text-left transition ${
              filtro === etapa.chave
                ? "border-zinc-500"
                : "border-zinc-800 hover:border-zinc-700"
            }`}
          >
            <p className="text-sm text-zinc-400">{etapa.titulo}</p>
            <h2 className="text-2xl font-bold mt-3">{porStatus[etapa.chave] ?? 0}</h2>
          </button>
        ))}
      </div>

      {loading ? (
        <Carregando />
      ) : error ? (
        <ErroAoCarregar mensagem={error} onRetry={reload} />
      ) : data && data.items.length === 0 ? (
        <div className="bg-zinc-900 border border-zinc-800 rounded-3xl">
          <Vazio
            titulo={filtro ? "Nada nesta etapa" : "Nenhuma devolução registrada"}
            descricao={
              filtro
                ? "Toque no cartão de novo para ver todas."
                : "Use “Rastrear agora” depois de importar os lançamentos do marketplace."
            }
          />
        </div>
      ) : (
        <div className="space-y-4">
          {data?.items.map((devolucao) => (
            <Cartao key={devolucao.id} devolucao={devolucao} />
          ))}
        </div>
      )}
    </div>
  )
}

function Cartao({ devolucao }: { devolucao: Devolucao }) {
  return (
    <div className="bg-zinc-900 border border-zinc-800 rounded-3xl p-6 shadow-xl">
      <div className="flex items-start justify-between gap-4 flex-wrap">
        <div className="flex items-center gap-4 min-w-0">
          <div className="w-12 h-12 rounded-2xl bg-white/5 border border-white/10 flex items-center justify-center text-zinc-300 shrink-0">
            <Undo2 size={20} />
          </div>

          <div className="min-w-0">
            <h3 className="font-semibold text-lg">
              {TIPOS[devolucao.tipo] ?? rotulo(devolucao.tipo)} · {brl(devolucao.valor)}
            </h3>
            <p className="text-sm text-zinc-400 mt-0.5 truncate">
              {devolucao.plataforma && `${rotulo(devolucao.plataforma)} · `}
              {devolucao.aberta_em && `aberta em ${dataBR(devolucao.aberta_em)}`}
            </p>
          </div>
        </div>

        <span
          className={`inline-flex items-center gap-1.5 px-3 py-1 rounded-full text-xs font-medium border ${TONS[devolucao.status]}`}
        >
          {devolucao.status === "concluida" && <CheckCircle2 size={13} />}
          {rotulo(devolucao.status)}
        </span>
      </div>

      <div className="mt-5 border-t border-zinc-800 pt-5 grid grid-cols-1 md:grid-cols-3 gap-4">
        <Elo
          Icone={ArrowLeftRight}
          titulo="Pedido de origem"
          valor={devolucao.pedido?.external_id ?? null}
        />

        <Elo
          Icone={FileText}
          titulo="NF da venda"
          valor={devolucao.nota_de_venda?.numero ?? null}
          legenda={
            devolucao.nota_de_venda?.emitida_em
              ? dataBR(devolucao.nota_de_venda.emitida_em)
              : undefined
          }
        />

        <Elo
          Icone={FileText}
          titulo="NF de devolução"
          valor={devolucao.nota_de_devolucao?.numero ?? null}
          legenda={
            devolucao.nota_de_devolucao?.emitida_em
              ? dataBR(devolucao.nota_de_devolucao.emitida_em)
              : undefined
          }
        />
      </div>

      {devolucao.pendencia && (
        <p className="mt-5 bg-white/5 border border-white/10 rounded-2xl px-4 py-3 text-sm text-zinc-300">
          {devolucao.pendencia}
        </p>
      )}
    </div>
  )
}

function Elo({
  Icone,
  titulo,
  valor,
  legenda,
}: {
  Icone: typeof FileText
  titulo: string
  valor: string | null
  legenda?: string
}) {
  return (
    <div className="flex items-start gap-3">
      <Icone size={16} className={valor ? "text-zinc-400 mt-0.5" : "text-zinc-700 mt-0.5"} />

      <div className="min-w-0">
        <p className="text-xs uppercase tracking-wide text-zinc-500">{titulo}</p>
        <p className={`text-sm mt-1 truncate ${valor ? "font-medium" : "text-zinc-600"}`}>
          {valor ?? "—"}
        </p>
        {legenda && <p className="text-[11px] text-zinc-600 mt-0.5">{legenda}</p>}
      </div>
    </div>
  )
}
