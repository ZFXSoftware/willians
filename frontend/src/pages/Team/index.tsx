import { useState } from "react"
import { Check, Copy, Mail, ShieldCheck, Trash2, UserPlus, Users } from "lucide-react"

import {
  alterarPapel,
  convidar,
  fetchEquipe,
  removerMembro,
  revogarConvite,
  type ConviteCriado,
  type Membro,
  type Papel,
} from "../../api/equipe"
import { errorMessage } from "../../api/client"
import { useResource } from "../../hooks/useResource"
import { dataBR, dataHoraBR } from "../../lib/format"
import { Carregando, ErroAoCarregar } from "../../components/Estados"

const TONS: Record<Papel, string> = {
  owner: "bg-emerald-500/15 text-emerald-400 border-emerald-500/20",
  admin: "bg-sky-500/15 text-sky-400 border-sky-500/20",
  member: "bg-zinc-500/15 text-zinc-300 border-zinc-500/20",
  viewer: "bg-zinc-500/15 text-zinc-400 border-zinc-500/20",
}

export default function Team() {
  const { data, loading, error, reload } = useResource(fetchEquipe)

  const [aviso, setAviso] = useState<string | null>(null)
  const [criado, setCriado] = useState<ConviteCriado | null>(null)

  const souAdmin = data?.meu_papel === "owner" || data?.meu_papel === "admin"

  async function executar(acao: () => Promise<unknown>, mensagemDeErro: string) {
    setAviso(null)

    try {
      await acao()
      reload()
    } catch (e) {
      setAviso(errorMessage(e, mensagemDeErro))
    }
  }

  return (
    <div className="space-y-6">
      <div>
        <p className="text-zinc-400 text-sm">Conciliação Financeira</p>
        <h1 className="text-3xl font-bold tracking-tight mt-1">Equipe</h1>
        <p className="text-sm text-zinc-400 mt-2 max-w-2xl">
          Quem tem acesso aos dados desta empresa. O convite é um link: quem
          recebe define a própria senha, que nunca passa por você.
        </p>
      </div>

      {aviso && (
        <div className="bg-red-500/10 border border-red-500/20 rounded-2xl px-5 py-4 text-sm text-red-300">
          {aviso}
        </div>
      )}

      {criado && <LinkDoConvite convite={criado} onFechar={() => setCriado(null)} />}

      {loading ? (
        <Carregando />
      ) : error ? (
        <ErroAoCarregar mensagem={error} onRetry={reload} />
      ) : (
        <>
          {souAdmin && (
            <FormularioDeConvite
              papeis={data!.papeis}
              podeConvidarOwner={data!.meu_papel === "owner"}
              onCriado={(c) => {
                setCriado(c)
                reload()
              }}
              onErro={setAviso}
            />
          )}

          <div className="bg-zinc-900 border border-zinc-800 rounded-3xl overflow-hidden">
            <div className="px-6 py-5 border-b border-zinc-800 flex items-center gap-3">
              <Users size={18} className="text-zinc-400" />
              <h2 className="font-semibold">Com acesso ({data?.membros.length ?? 0})</h2>
            </div>

            <div className="divide-y divide-zinc-800">
              {data?.membros.map((membro) => (
                <LinhaMembro
                  key={membro.id}
                  membro={membro}
                  papeis={data.papeis}
                  editavel={souAdmin}
                  podeDefinirOwner={data.meu_papel === "owner"}
                  onPapel={(role) =>
                    executar(() => alterarPapel(membro.id, role), "Não foi possível alterar")
                  }
                  onRemover={() =>
                    executar(() => removerMembro(membro.id), "Não foi possível remover")
                  }
                />
              ))}
            </div>
          </div>

          {(data?.convites.length ?? 0) > 0 && (
            <div className="bg-zinc-900 border border-zinc-800 rounded-3xl overflow-hidden">
              <div className="px-6 py-5 border-b border-zinc-800 flex items-center gap-3">
                <Mail size={18} className="text-zinc-400" />
                <h2 className="font-semibold">Convites em aberto</h2>
              </div>

              <div className="divide-y divide-zinc-800">
                {data?.convites.map((convite) => (
                  <div key={convite.id} className="px-6 py-4 flex items-center justify-between gap-4 flex-wrap">
                    <div className="min-w-0">
                      <p className="font-medium truncate">{convite.email}</p>
                      <p className="text-xs text-zinc-500 mt-0.5">
                        {convite.papel} · expira em {dataBR(convite.expira_em)}
                        {convite.convidado_por && ` · por ${convite.convidado_por}`}
                      </p>
                    </div>

                    {souAdmin && (
                      <button
                        onClick={() =>
                          executar(() => revogarConvite(convite.id), "Não foi possível revogar")
                        }
                        className="text-sm text-zinc-400 hover:text-red-400 transition"
                      >
                        Revogar
                      </button>
                    )}
                  </div>
                ))}
              </div>

              <p className="px-6 py-4 text-xs text-zinc-500 border-t border-zinc-800">
                O link de cada convite só aparece no momento em que é criado. Se
                você o perdeu, revogue este e crie outro.
              </p>
            </div>
          )}
        </>
      )}
    </div>
  )
}

function FormularioDeConvite({
  papeis,
  podeConvidarOwner,
  onCriado,
  onErro,
}: {
  papeis: Array<{ valor: Papel; rotulo: string; escreve: boolean }>
  podeConvidarOwner: boolean
  onCriado: (c: ConviteCriado) => void
  onErro: (m: string) => void
}) {
  const [email, setEmail] = useState("")
  const [papel, setPapel] = useState<Papel>("member")
  const [enviando, setEnviando] = useState(false)

  const disponiveis = papeis.filter((p) => p.valor !== "owner" || podeConvidarOwner)

  async function criar() {
    setEnviando(true)

    try {
      onCriado(await convidar(email.trim(), papel))
      setEmail("")
    } catch (e) {
      onErro(errorMessage(e, "Não foi possível criar o convite"))
    } finally {
      setEnviando(false)
    }
  }

  return (
    <div className="bg-zinc-900 border border-zinc-800 rounded-3xl p-6 shadow-xl">
      <div className="flex items-center gap-3">
        <UserPlus size={18} className="text-zinc-400" />
        <h2 className="font-semibold">Convidar alguém</h2>
      </div>

      <div className="mt-5 flex flex-col md:flex-row gap-3">
        <input
          type="email"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          placeholder="pessoa@empresa.com"
          autoComplete="off"
          className="flex-1 bg-zinc-950 border border-zinc-800 focus:border-zinc-600 outline-none rounded-xl px-4 py-2.5 text-sm transition"
        />

        <select
          value={papel}
          onChange={(e) => setPapel(e.target.value as Papel)}
          className="bg-zinc-950 border border-zinc-800 focus:border-zinc-600 outline-none rounded-xl px-4 py-2.5 text-sm transition"
        >
          {disponiveis.map((p) => (
            <option key={p.valor} value={p.valor}>
              {p.rotulo}
              {p.escreve ? " — pode alterar" : " — só leitura"}
            </option>
          ))}
        </select>

        <button
          onClick={criar}
          disabled={enviando || !email.trim()}
          className="bg-emerald-600 hover:bg-emerald-500 disabled:opacity-40 px-5 py-2.5 rounded-xl text-sm font-medium transition"
        >
          {enviando ? "Gerando..." : "Gerar link"}
        </button>
      </div>
    </div>
  )
}

function LinkDoConvite({ convite, onFechar }: { convite: ConviteCriado; onFechar: () => void }) {
  const [copiado, setCopiado] = useState(false)

  async function copiar() {
    await navigator.clipboard.writeText(convite.link)
    setCopiado(true)
    setTimeout(() => setCopiado(false), 2500)
  }

  return (
    <div className="bg-emerald-500/10 border border-emerald-500/20 rounded-3xl p-6">
      <div className="flex items-start justify-between gap-4">
        <div className="min-w-0">
          <h3 className="font-medium text-emerald-300">
            Link para {convite.email}
          </h3>
          <p className="text-sm text-zinc-400 mt-1">{convite.aviso}</p>
        </div>

        <button onClick={onFechar} className="text-sm text-zinc-500 hover:text-white transition">
          fechar
        </button>
      </div>

      <div className="mt-4 flex items-center gap-2 bg-zinc-950 border border-zinc-800 rounded-2xl px-4 py-3">
        <code className="flex-1 text-xs font-mono truncate">{convite.link}</code>

        <button
          onClick={copiar}
          className="flex items-center gap-1.5 text-xs text-zinc-300 hover:text-white transition shrink-0"
        >
          {copiado ? <Check size={14} /> : <Copy size={14} />}
          {copiado ? "Copiado" : "Copiar"}
        </button>
      </div>

      <p className="text-xs text-zinc-500 mt-3">
        Envie por onde preferir. Vale uma vez só e expira em{" "}
        {dataBR(convite.expira_em)}.
      </p>
    </div>
  )
}

function LinhaMembro({
  membro,
  papeis,
  editavel,
  podeDefinirOwner,
  onPapel,
  onRemover,
}: {
  membro: Membro
  papeis: Array<{ valor: Papel; rotulo: string; escreve: boolean }>
  editavel: boolean
  podeDefinirOwner: boolean
  onPapel: (role: Papel) => void
  onRemover: () => void
}) {
  const disponiveis = papeis.filter((p) => p.valor !== "owner" || podeDefinirOwner)

  return (
    <div className="px-6 py-4 flex items-center justify-between gap-4 flex-wrap">
      <div className="min-w-0">
        <p className="font-medium truncate">
          {membro.nome}
          {membro.sou_eu && <span className="text-zinc-500 font-normal"> · você</span>}
        </p>
        <p className="text-xs text-zinc-500 mt-0.5 truncate">
          {membro.email}
          {membro.ultimo_acesso && ` · último acesso ${dataHoraBR(membro.ultimo_acesso)}`}
        </p>
      </div>

      <div className="flex items-center gap-3 shrink-0">
        {editavel ? (
          <select
            value={membro.papel}
            onChange={(e) => onPapel(e.target.value as Papel)}
            className="bg-zinc-950 border border-zinc-800 focus:border-zinc-600 outline-none rounded-xl px-3 py-2 text-sm transition"
          >
            {disponiveis.map((p) => (
              <option key={p.valor} value={p.valor}>
                {p.rotulo}
              </option>
            ))}
          </select>
        ) : (
          <span className={`px-3 py-1 rounded-full text-xs font-medium border ${TONS[membro.papel]}`}>
            {papeis.find((p) => p.valor === membro.papel)?.rotulo ?? membro.papel}
          </span>
        )}

        {membro.escreve && <ShieldCheck size={15} className="text-emerald-400" />}

        {editavel && !membro.sou_eu && (
          <button
            onClick={onRemover}
            title="Remover o acesso desta pessoa"
            className="p-2 rounded-xl border border-zinc-800 text-zinc-400 hover:text-red-400 hover:border-red-500/30 transition"
          >
            <Trash2 size={15} />
          </button>
        )}
      </div>
    </div>
  )
}
