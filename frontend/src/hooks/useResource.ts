import { useCallback, useEffect, useState } from "react"
import { errorMessage } from "../api/client"

interface Estado<T> {
  data: T | null
  /** Só a PRIMEIRA carga. Recarregar não apaga a tela. */
  loading: boolean
  /** Há uma busca em andamento com dados já na tela. */
  recarregando: boolean
  error: string | null
  reload: () => void
}

// Busca com estados de carregando/erro e recarga manual. `deps` segue a mesma
// semântica do useEffect: mudou, busca de novo.
//
// `loading` vale só para a primeira carga. Antes ele subia em toda recarga, e
// a tela inteira virava "Carregando..." por um instante — o que DESMONTA os
// componentes e apaga o estado local deles. Foi assim que o resultado do
// "Enviar ao OMIE" piscava e sumia: o botão pedia a recarga, a recarga trocava
// a tela, e o resultado morria junto com o componente.
export function useResource<T>(
  loader: () => Promise<T>,
  deps: unknown[] = [],
): Estado<T> {
  const [data, setData] = useState<T | null>(null)
  const [carregouUmaVez, setCarregouUmaVez] = useState(false)
  const [recarregando, setRecarregando] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [tick, setTick] = useState(0)

  const reload = useCallback(() => setTick((t) => t + 1), [])

  useEffect(() => {
    let active = true

    setRecarregando(true)
    setError(null)

    loader()
      .then((d) => {
        if (active) setData(d)
      })
      .catch((e) => {
        if (active) setError(errorMessage(e, "Não foi possível carregar os dados"))
      })
      .finally(() => {
        if (!active) return

        setRecarregando(false)
        setCarregouUmaVez(true)
      })

    return () => {
      active = false
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [...deps, tick])

  return {
    data,
    loading: !carregouUmaVez && recarregando,
    recarregando,
    error,
    reload,
  }
}
