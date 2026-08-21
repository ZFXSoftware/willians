import { useState } from "react"
import { useNavigate, useParams } from "react-router-dom"
import { CheckCircle2, ShieldAlert } from "lucide-react"

import { aceitarConvite, lerConvite } from "../../api/equipe"
import { errorMessage } from "../../api/client"
import { useResource } from "../../hooks/useResource"
import { useAuth } from "../../store/useAuth"
import { Carregando } from "../../components/Estados"

// Página pública: quem abre o link ainda não tem conta, e é o que vem fazer.
export default function Invite() {
  const { token = "" } = useParams()
  const navigate = useNavigate()

  const { data, loading, error } = useResource(() => lerConvite(token), [token])

  const [nome, setNome] = useState("")
  const [senha, setSenha] = useState("")
  const [enviando, setEnviando] = useState(false)
  const [aviso, setAviso] = useState<string | null>(null)
  const [pronto, setPronto] = useState<string | null>(null)

  const setSession = useAuth((s) => s.setSession)

  async function aceitar() {
    setEnviando(true)
    setAviso(null)

    try {
      const resposta = await aceitarConvite(token, { name: nome, password: senha })

      if (resposta.ja_tinha_conta) {
        setPronto(resposta.mensagem)
        return
      }

      // Entra já autenticado: pedir para logar em seguida seria atrito à toa.
      setSession(resposta)
      navigate("/", { replace: true })
    } catch (e) {
      setAviso(errorMessage(e, "Não foi possível concluir"))
    } finally {
      setEnviando(false)
    }
  }

  return (
    <div className="min-h-screen flex items-center justify-center px-6 py-12 bg-[#0b1120] text-zinc-100">
      <div className="w-full max-w-md">
        {loading ? (
          <Carregando texto="Conferindo o convite..." />
        ) : error ? (
          <Cartao>
            <div className="flex items-start gap-3">
              <ShieldAlert size={20} className="text-red-400 mt-0.5 shrink-0" />
              <div>
                <h1 className="font-semibold text-lg">Convite inválido ou expirado</h1>
                <p className="text-sm text-zinc-400 mt-2">
                  Peça um link novo a quem administra a empresa. Cada link vale
                  uma vez só e tem prazo.
                </p>
              </div>
            </div>

            <button
              onClick={() => navigate("/login")}
              className="mt-6 w-full bg-zinc-800 hover:bg-zinc-700 px-5 py-2.5 rounded-xl text-sm transition"
            >
              Ir para o login
            </button>
          </Cartao>
        ) : pronto ? (
          <Cartao>
            <div className="flex items-start gap-3">
              <CheckCircle2 size={20} className="text-emerald-400 mt-0.5 shrink-0" />
              <div>
                <h1 className="font-semibold text-lg">Tudo certo</h1>
                <p className="text-sm text-zinc-400 mt-2">{pronto}</p>
              </div>
            </div>

            <button
              onClick={() => navigate("/login")}
              className="mt-6 w-full bg-emerald-600 hover:bg-emerald-500 px-5 py-2.5 rounded-xl text-sm font-medium transition"
            >
              Entrar
            </button>
          </Cartao>
        ) : data ? (
          <Cartao>
            <p className="text-zinc-400 text-sm">Convite para</p>
            <h1 className="text-2xl font-bold tracking-tight mt-1">{data.empresa}</h1>
            <p className="text-sm text-zinc-400 mt-3">
              <span className="text-zinc-300">{data.email}</span>
              {" · "}
              {data.papel === "viewer" ? "somente leitura" : `perfil ${data.papel}`}
            </p>

            {data.usuario_existente ? (
              <>
                <p className="mt-6 text-sm text-zinc-400">
                  Você já tem conta com este e-mail. Ao aceitar, ela passa a ter
                  acesso a esta empresa — sua senha continua a mesma.
                </p>

                <button
                  onClick={aceitar}
                  disabled={enviando}
                  className="mt-6 w-full bg-emerald-600 hover:bg-emerald-500 disabled:opacity-40 px-5 py-3 rounded-xl text-sm font-medium transition"
                >
                  {enviando ? "Aceitando..." : "Aceitar convite"}
                </button>
              </>
            ) : (
              <>
                <div className="mt-6 space-y-3">
                  <div>
                    <label className="text-sm text-zinc-400">Seu nome</label>
                    <input
                      value={nome}
                      onChange={(e) => setNome(e.target.value)}
                      className="mt-1.5 w-full bg-zinc-950 border border-zinc-800 focus:border-zinc-600 outline-none rounded-xl px-4 py-2.5 text-sm transition"
                    />
                  </div>

                  <div>
                    <label className="text-sm text-zinc-400">Crie uma senha</label>
                    <input
                      type="password"
                      value={senha}
                      onChange={(e) => setSenha(e.target.value)}
                      autoComplete="new-password"
                      className="mt-1.5 w-full bg-zinc-950 border border-zinc-800 focus:border-zinc-600 outline-none rounded-xl px-4 py-2.5 text-sm transition"
                    />
                    <p className="text-xs text-zinc-500 mt-1.5">
                      Pelo menos 12 caracteres. Só você a conhece — nem quem
                      convidou.
                    </p>
                  </div>
                </div>

                <button
                  onClick={aceitar}
                  disabled={enviando || senha.length < 12 || !nome.trim()}
                  className="mt-6 w-full bg-emerald-600 hover:bg-emerald-500 disabled:opacity-40 px-5 py-3 rounded-xl text-sm font-medium transition"
                >
                  {enviando ? "Criando..." : "Criar acesso e entrar"}
                </button>
              </>
            )}

            {aviso && <p className="mt-4 text-sm text-red-300">{aviso}</p>}
          </Cartao>
        ) : null}
      </div>
    </div>
  )
}

function Cartao({ children }: { children: React.ReactNode }) {
  return (
    <div className="bg-zinc-900 border border-zinc-800 rounded-3xl p-8 shadow-2xl">{children}</div>
  )
}
