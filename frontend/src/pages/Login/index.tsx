import { useState } from "react"
import { Link, useNavigate } from "react-router-dom"
import { login } from "../../api/auth"
import { errorMessage } from "../../api/client"
import "./login.css"

export default function Login() {
  const [email, setEmail] = useState("")
  const [password, setPassword] = useState("")
  const [error, setError] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)

  const navigate = useNavigate()

  async function handleLogin(e: React.FormEvent) {
    e.preventDefault()

    setError(null)
    setLoading(true)

    try {
      await login(email, password)
      navigate("/", { replace: true })
    } catch (err) {
      setError(errorMessage(err, "Não foi possível entrar"))
      setLoading(false)
    }
  }

  return (
    <div className="login-container">
      <form onSubmit={handleLogin} className="login-card">
        <h1 className="login-title">Willians</h1>

        {error && <div className="login-error">{error}</div>}

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
          placeholder="Senha"
          className="login-input"
          autoComplete="current-password"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
          required
        />

        <button type="submit" className="login-button" disabled={loading}>
          {loading ? "Entrando..." : "Entrar"}
        </button>

        <div className="login-footer">
          Não tem conta? <Link to="/register">Criar agora</Link>
        </div>
      </form>
    </div>
  )
}
