import { useState } from "react"
import { AlertTriangle, CheckCircle2, HelpCircle, RefreshCw, Scale } from "lucide-react"

import {
  conferirSaldos,
  fetchSaldos,
  type DetalheConferencia,
  type MotivoSemEspelho,
  type SaldoDaConta,
  type SituacaoSaldo,
} from "../../api/saldos"
import { errorMessage } from "../../api/client"
import { useResource } from "../../hooks/useResource"
import { brl, dataBR, rotulo } from "../../lib/format"
import { Carregando, ErroAoCarregar, Vazio } from "../../components/Estados"

const SITUACOES: Record<SituacaoSaldo, { texto: string; classe: string; Icone: typeof CheckCircle2 }> = {
  confere: {
    texto: "Confere",
    classe: "bg-emerald-500/15 text-emerald-400 border-emerald-500/20",
    Icone: CheckCircle2,
  },
  divergente: {
    texto: "Diferença",
    classe: "bg-red-500/15 text-red-400 border-red-500/20",
    Icone: AlertTriangle,
  },
  nao_conferido: {
    texto: "Nunca conferido",
    classe: "bg-zinc-500/15 text-zinc-300 border-zinc-500/20",
    Icone: HelpCircle,
  },
}

// Espelha SEM_PROVIDENCIA do ConciliacaoDeSaldo: motivos que não pedem ação.
const SEM_PROVIDENCIA: MotivoSemEspelho[] = [
  "sem_integracao",
  "sem_suporte",
  "relatorio_em_geracao",
  "limite_de_requisicoes",
]

export default function Balances() {
  const { data, loading, error, reload } = useResource(fetchSaldos)

  const [conferindo, setConferindo] = useState(false)
  const [aviso, setAviso] = useState<string | null>(null)
  const [semEspelho, setSemEspelho] = useState<DetalheConferencia[]>([])

  // Nem toda conta sem espelho é problema: plataforma que não expõe saldo e
  // relatório ainda sendo gerado não pedem nada de ninguém. Misturar as duas
  // coisas num aviso amarelo só ensina o usuário a ignorar o aviso.
  const pendentes = semEspelho.filter((d) => !SEM_PROVIDENCIA.includes(d.motivo ?? "erro"))
  const informativos = semEspelho.filter((d) => SEM_PROVIDENCIA.includes(d.motivo ?? "erro"))

  async function conferir() {
    setConferindo(true)
    setAviso(null)

    try {
      const resultado = await conferirSaldos()

      setSemEspelho(resultado.detalhes.filter((d) => d.situacao === "sem_espelho"))

      reload()
    } catch (e) {
      setAviso(errorMessage(e, "Não foi possível conferir os saldos"))
    } finally {
      setConferindo(false)
    }
  }

  return (
    <div className="space-y-6">
      <div className="flex flex-col lg:flex-row lg:items-center lg:justify-between gap-4">
        <div>
          <p className="text-zinc-400 text-sm">Conciliação Financeira</p>
          <h1 className="text-3xl font-bold tracking-tight mt-1">Conta virtual</h1>
          <p className="text-sm text-zinc-400 mt-2 max-w-2xl">
            O saldo que a plataforma diz ter, ao lado do que o nosso razão
            calcula. A diferença aponta dinheiro que entrou ou saiu sem passar
            por um lançamento.
          </p>
        </div>

        <button
          onClick={conferir}
          disabled={conferindo}
          className="flex items-center gap-2 bg-emerald-600 hover:bg-emerald-500 disabled:opacity-40 px-5 py-3 rounded-xl text-sm font-medium transition shrink-0"
        >
          <RefreshCw size={15} className={conferindo ? "animate-spin" : ""} />
          {conferindo ? "Conferindo..." : "Conferir agora"}
        </button>
      </div>

      {aviso && (
        <div className="bg-red-500/10 border border-red-500/20 rounded-2xl px-5 py-4 text-sm text-red-300">
          {aviso}
        </div>
      )}

      {pendentes.length > 0 && (
        <div className="bg-yellow-500/10 border border-yellow-500/20 rounded-2xl px-5 py-4 text-sm text-yellow-300 space-y-1">
          <p className="font-medium">Estas contas precisam de você:</p>
          {pendentes.map((d) => (
            <p key={d.platform_account_id} className="text-yellow-200/80">
              {d.mensagem ?? rotulo(d.platform)}
            </p>
          ))}
        </div>
      )}

      {informativos.length > 0 && (
        <div className="bg-zinc-500/10 border border-zinc-500/20 rounded-2xl px-5 py-4 text-sm text-zinc-300 space-y-1">
          <p className="font-medium">Não conferidas, sem nada a fazer:</p>
          {informativos.map((d) => (
            <p key={d.platform_account_id} className="text-zinc-400">
              {d.mensagem ?? rotulo(d.platform)}
            </p>
          ))}
        </div>
      )}

      {loading ? (
        <Carregando />
      ) : error ? (
        <ErroAoCarregar mensagem={error} onRetry={reload} />
      ) : (
        <>
          <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
            <Cartao titulo="Conferem" valor={data?.resumo.confere ?? 0} tom="text-emerald-400" />
            <Cartao titulo="Com diferença" valor={data?.resumo.divergente ?? 0} tom="text-red-400" />
            <Cartao titulo="Nunca conferidas" valor={data?.resumo.nao_conferido ?? 0} tom="text-zinc-300" />
          </div>

          {data && data.items.length === 0 ? (
            <div className="bg-zinc-900 border border-zinc-800 rounded-3xl">
              <Vazio
                titulo="Nenhuma conta ativa"
                descricao="Cadastre e conecte uma conta de marketplace para espelhar o saldo."
              />
            </div>
          ) : (
            <div className="space-y-4">
              {data?.items.map((conta) => (
                <LinhaDeSaldo key={conta.platform_account_id} conta={conta} />
              ))}
            </div>
          )}
        </>
      )}
    </div>
  )
}

function Cartao({ titulo, valor, tom }: { titulo: string; valor: number; tom: string }) {
  return (
    <div className="bg-zinc-900 border border-zinc-800 rounded-3xl p-5 shadow-xl">
      <p className="text-sm text-zinc-400">{titulo}</p>
      <h2 className={`text-2xl font-bold mt-3 ${tom}`}>{valor}</h2>
    </div>
  )
}

function LinhaDeSaldo({ conta }: { conta: SaldoDaConta }) {
  const situacao = SITUACOES[conta.situacao]
  const { Icone } = situacao

  return (
    <div className="bg-zinc-900 border border-zinc-800 rounded-3xl p-6 shadow-xl">
      <div className="flex items-start justify-between gap-4 flex-wrap">
        <div className="flex items-center gap-4 min-w-0">
          <div className="w-12 h-12 rounded-2xl bg-white/5 border border-white/10 flex items-center justify-center text-zinc-300 shrink-0">
            <Scale size={20} />
          </div>

          <div className="min-w-0">
            <h3 className="font-semibold text-lg truncate">{conta.nome}</h3>
            <p className="text-sm text-zinc-400 mt-0.5">
              {rotulo(conta.plataforma)}
              {conta.conferido_em && ` · conferido em ${dataBR(conta.conferido_em)}`}
            </p>
          </div>
        </div>

        <span
          className={`inline-flex items-center gap-1.5 px-3 py-1 rounded-full text-xs font-medium border ${situacao.classe}`}
        >
          <Icone size={13} />
          {situacao.texto}
        </span>
      </div>

      {conta.situacao === "nao_conferido" ? (
        <p className="mt-5 text-sm text-zinc-500 border-t border-zinc-800 pt-5">
          Ainda não houve conferência para esta conta. Use “Conferir agora”.
        </p>
      ) : (
        <div className="mt-5 border-t border-zinc-800 pt-5 grid grid-cols-1 md:grid-cols-3 gap-5">
          <Coluna
            titulo="Na plataforma"
            legenda={conta.origem_do_saldo ?? undefined}
            linhas={[
              ["Disponível", conta.saldo_plataforma.disponivel],
              ["Total", conta.saldo_plataforma.total ?? null],
            ]}
          />

          <Coluna
            titulo="No nosso razão"
            linhas={[
              ["Disponível", conta.saldo_interno.disponivel],
              ["A liberar", conta.saldo_interno.futuro],
              ["Bloqueado", conta.saldo_interno.bloqueado ?? null],
            ]}
          />

          <div>
            <p className="text-xs uppercase tracking-wide text-zinc-500">Diferença</p>
            <p
              className={`text-2xl font-bold mt-2 ${
                conta.situacao === "divergente" ? "text-red-400" : "text-emerald-400"
              }`}
            >
              {conta.diferenca ? brl(conta.diferenca) : "—"}
            </p>
            {conta.situacao === "divergente" && (
              <p className="text-xs text-zinc-500 mt-2">
                Também registrada em Divergências, para acompanhamento.
              </p>
            )}
          </div>
        </div>
      )}
    </div>
  )
}

function Coluna({
  titulo,
  legenda,
  linhas,
}: {
  titulo: string
  legenda?: string
  linhas: Array<[string, string | null]>
}) {
  return (
    <div>
      <p className="text-xs uppercase tracking-wide text-zinc-500">{titulo}</p>

      <div className="mt-2 space-y-1.5">
        {linhas.map(([nome, valor]) => (
          <div key={nome} className="flex items-center justify-between gap-3 text-sm">
            <span className="text-zinc-400">{nome}</span>
            <span className="font-medium">{valor ? brl(valor) : "—"}</span>
          </div>
        ))}
      </div>

      {legenda && <p className="text-[11px] text-zinc-600 mt-2">fonte: {legenda}</p>}
    </div>
  )
}
