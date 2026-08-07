import { Navigate } from "react-router-dom"
import { useEffect, useState } from "react"
import { useAuth } from "../store/useAuth"
import { fetchMe } from "../api/auth"

type Status = "checking" | "authenticated" | "anonymous"

export default function PrivateRoute({
  children,
}: {
  children: React.ReactNode
}) {
  const token = useAuth((state) => state.token)

  const [status, setStatus] = useState<Status>(token ? "checking" : "anonymous")

  useEffect(() => {
    if (!token) {
      setStatus("anonymous")
      return
    }

    let active = true

    // O token guardado pode ter sido revogado ou expirado no servidor — só o
    // /auth/me confirma que a sessão ainda vale.
    fetchMe()
      .then(() => active && setStatus("authenticated"))
      .catch(() => {
        if (!active) return

        useAuth.getState().clear()
        setStatus("anonymous")
      })

    return () => {
      active = false
    }
  }, [token])

  if (status === "checking") {
    return (
      <div className="min-h-screen bg-zinc-950 flex items-center justify-center text-zinc-400">
        Carregando...
      </div>
    )
  }

  if (status === "anonymous") {
    return <Navigate to="/login" replace />
  }

  return <>{children}</>
}
