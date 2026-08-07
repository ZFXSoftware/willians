import { AlertTriangle, Inbox, RefreshCw } from "lucide-react"

export function Carregando({ texto = "Carregando..." }: { texto?: string }) {
  return (
    <div className="flex items-center justify-center gap-3 py-16 text-zinc-400">
      <RefreshCw size={16} className="animate-spin" />
      {texto}
    </div>
  )
}

export function ErroAoCarregar({
  mensagem,
  onRetry,
}: {
  mensagem: string
  onRetry?: () => void
}) {
  return (
    <div className="bg-red-500/5 border border-red-500/20 rounded-3xl p-6 flex flex-col lg:flex-row lg:items-center lg:justify-between gap-4">
      <div className="flex items-start gap-3">
        <AlertTriangle size={20} className="text-red-400 mt-0.5 shrink-0" />
        <div>
          <h3 className="font-medium text-red-300">Não foi possível carregar</h3>
          <p className="text-sm text-zinc-400 mt-1">{mensagem}</p>
        </div>
      </div>

      {onRetry && (
        <button
          onClick={onRetry}
          className="flex items-center gap-2 bg-zinc-800 hover:bg-zinc-700 transition px-4 py-2.5 rounded-xl text-sm shrink-0"
        >
          <RefreshCw size={15} />
          Tentar de novo
        </button>
      )}
    </div>
  )
}

export function Vazio({
  titulo,
  descricao,
  acao,
}: {
  titulo: string
  descricao?: string
  acao?: React.ReactNode
}) {
  return (
    <div className="flex flex-col items-center justify-center py-16 px-6 text-center">
      <div className="w-12 h-12 rounded-2xl bg-white/5 border border-white/10 flex items-center justify-center text-zinc-500">
        <Inbox size={20} />
      </div>

      <h3 className="font-medium mt-4">{titulo}</h3>

      {descricao && (
        <p className="text-sm text-zinc-400 mt-2 max-w-md">{descricao}</p>
      )}

      {acao && <div className="mt-5">{acao}</div>}
    </div>
  )
}

const TONS: Record<string, string> = {
  matched: "bg-emerald-500/15 text-emerald-400 border-emerald-500/20",
  resolved: "bg-emerald-500/15 text-emerald-400 border-emerald-500/20",
  connected: "bg-emerald-500/15 text-emerald-400 border-emerald-500/20",
  active: "bg-emerald-500/15 text-emerald-400 border-emerald-500/20",
  divergent: "bg-red-500/15 text-red-400 border-red-500/20",
  open: "bg-red-500/15 text-red-400 border-red-500/20",
  expired: "bg-red-500/15 text-red-400 border-red-500/20",
  revoked: "bg-red-500/15 text-red-400 border-red-500/20",
  error: "bg-red-500/15 text-red-400 border-red-500/20",
  manual_review: "bg-yellow-500/15 text-yellow-400 border-yellow-500/20",
  pending: "bg-yellow-500/15 text-yellow-400 border-yellow-500/20",
  analyzing: "bg-yellow-500/15 text-yellow-400 border-yellow-500/20",
}

export function Selo({ status, texto }: { status: string; texto: string }) {
  const tom = TONS[status] ?? "bg-zinc-500/15 text-zinc-300 border-zinc-500/20"

  return (
    <span className={`inline-flex items-center px-3 py-1 rounded-full text-xs font-medium border ${tom}`}>
      {texto}
    </span>
  )
}
