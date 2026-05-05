import { useState } from "react"
import { supabase } from "../../lib/supabase"
import { useNavigate } from "react-router-dom"
import "./login.css"

export default function Login() {
  const [email, setEmail] = useState("")
  const [password, setPassword] = useState("")
  const [loading, setLoading] = useState(false)

  const navigate = useNavigate()

  async function handleLogin(e: any) {
    e.preventDefault()
    setLoading(true)

    const { data, error } = await supabase.auth.signInWithPassword({
      email,
      password,
    })

    if (error) {
      alert(error.message)
      setLoading(false)
      return
    }

    navigate("/")
  }
  return (
    <div className="login-container">
      <form onSubmit={handleLogin} className="login-card">
        <h1 className="login-title">WillBank</h1>

        <input
          type="email"
          placeholder="Email"
          className="login-input"
          value={email}
          onChange={(e) => setEmail(e.target.value)}
        />

        <input
          type="password"
          placeholder="Senha"
          className="login-input"
          value={password}
          onChange={(e) => setPassword(e.target.value)}
        />

        <button
          type="submit"
          className="login-button"
          disabled={loading}
        >
          {loading ? "Entrando..." : "Entrar"}
        </button>

        <div className="login-footer">
          Sistema de conciliação bancária
        </div>
      </form>
    </div>
  )
}