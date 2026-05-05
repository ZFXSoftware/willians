import { Navigate } from "react-router-dom"
import { useEffect, useState } from "react"
import { supabase } from "../lib/supabase"

export default function PrivateRoute({ children }: any) {
  const [session, setSession] = useState<any>(null)

  useEffect(() => {
    supabase.auth.getSession().then(({ data }) => {
      setSession(data.session)
    })
  }, [])

  if (session === null) {
    return null // loading
  }

  if (!session) {
    return <Navigate to="/login" />
  }

  return children
}