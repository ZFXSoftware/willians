import { Navigate } from "react-router-dom"
import { useEffect, useState } from "react"
import { supabase } from "../lib/supabase"

export default function PrivateRoute({
  children,
}: {
  children: React.ReactNode
}) {
  const [session, setSession] = useState<any>(undefined)

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session)
    })

    const {
      data: { subscription },
    } = supabase.auth.onAuthStateChange((_event, session) => {
      setSession(session)
    })

    return () => {
      subscription.unsubscribe()
    }
  }, [])

  // loading
  if (session === undefined) {
    return (
      <div className="min-h-screen bg-zinc-950 flex items-center justify-center text-zinc-400">
        Carregando...
      </div>
    )
  }

  // não autenticado
  if (!session) {
    return <Navigate to="/login" replace />
  }

  // autenticado
  return <>{children}</>
}