import { useCallback, useEffect, useState } from "react"
import { errorMessage } from "../api/client"

interface Estado<T> {
  data: T | null
  loading: boolean
  error: string | null
  reload: () => void
}

// Busca com estados de carregando/erro e recarga manual. `deps` segue a mesma
// semântica do useEffect: mudou, busca de novo.
export function useResource<T>(
  loader: () => Promise<T>,
  deps: unknown[] = [],
): Estado<T> {
  const [data, setData] = useState<T | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [tick, setTick] = useState(0)

  const reload = useCallback(() => setTick((t) => t + 1), [])

  useEffect(() => {
    let active = true

    setLoading(true)
    setError(null)

    loader()
      .then((d) => {
        if (active) setData(d)
      })
      .catch((e) => {
        if (active) setError(errorMessage(e, "Não foi possível carregar os dados"))
      })
      .finally(() => {
        if (active) setLoading(false)
      })

    return () => {
      active = false
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, tick])

  return { data, loading, error, reload }
}
