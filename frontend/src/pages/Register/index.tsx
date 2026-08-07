import { useState } from "react"
import { Link, useNavigate } from "react-router-dom"
import { register } from "../../api/auth"
import { errorMessage } from "../../api/client"
import "../Login/login.css"

const MIN_PASSWORD = 8

export default function Register() {
  const [name, setName] = useState("")
  const [tenantName, setTenantName] = useState("")
  const [email, setEmail] = useState("")
  const [password, setPassword] = useState("")
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)

  const navigate = useNavigate()

  async function handleRegister(e: React.FormEvent) {
    e.preventDefault()

    if (password.length < MIN_PASSWORD) {
      setError(`A senha precisa ter ao menos ${MIN_PASSWORD} caracteres`)
      return
    }

    setError(null)
    setLoading(true)

    try {
      // O cadastro já devolve a sessão — não precisa passar pelo login.
      await register({
        name,
        email,
        password,
        tenant_name: tenantName || undefined,
      })

      navigate("/", { replace: true })
    } catch (err) {
      setError(errorMessage(err, "Não foi possível criar a conta"))
      setLoading(false)
    }
  }

  return (
    <div className="login-container">
      <form onSubmit={handleRegister} className="login-card">
        <h1 className="login-title">Criar conta</h1>

        {error && <div className="login-error">{error}</div>}

        <input
          type="text"
          placeholder="Seu nome"
          className="login-input"
          autoComplete="name"
          value={name}
          onChange={(e) => setName(e.target.value)}
          required
        />

        <input
          type="text"
          placeholder="Nome da empresa (opcional)"
          className="login-input"
          autoComplete="organization"
          value={tenantName}
          onChange={(e) => setTenantName(e.target.value)}
        />

        <input
          type="email"
          placeholder="Email"
          className="login-input"
          autoComplete="email"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
          required
        />

        <input
          type="password"
          placeholder={`Senha (mínimo ${MIN_PASSWORD} caracteres)`}
          className="login-input"
          autoComplete="new-password"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          required
        />

        <button type="submit" className="login-button" disabled={loading}>
          {loading ? "Criando..." : "Cadastrar"}
        </button>

        <div className="login-footer">
          Já tem conta? <Link to="/login">Entrar</Link>
        </div>
      </form>
    </div>
  )
}
