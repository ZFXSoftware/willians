// A identificação de uma nota fiscal, igual em toda tela que a mostra.
//
// Uma nota é identificada pelo par NÚMERO + SÉRIE. O cliente usa quatro séries — 5, 2, 9
// e 4 — e o mesmo número se repete entre elas, então o número sozinho é ambíguo.
//
// A chave de acesso de 44 dígitos é o que o DANFE traz para consulta na SEFAZ. Ela não
// cabe na linha de uma tabela, então aparece encurtada, com o valor inteiro ao passar o
// mouse e um clique para copiar — que é o único uso real dela: colar no portal.
import { useState } from "react"

export default function NotaFiscal({
  numero,
  serie,
  chave,
  children,
}: {
  numero: string | null
  serie?: string | null
  chave?: string | null
  children?: React.ReactNode
}) {
  const [copiada, setCopiada] = useState(false)

  if (!numero) return <span className="text-amber-400">sem nota</span>

  async function copiar() {
    if (!chave) return

    try {
      await navigator.clipboard.writeText(chave)
      setCopiada(true)
      setTimeout(() => setCopiada(false), 1500)
    } catch {
      // Área de transferência bloqueada pelo navegador: a chave continua visível no
      // título, e insistir com um alerta não ajudaria ninguém.
    }
  }

  return (
    <span className="inline-flex flex-col gap-0.5 leading-tight">
      <span className="text-zinc-300">
        {numero}
        {serie && <span className="text-zinc-500"> · sér. {serie}</span>}
        {children}
      </span>

      {chave && (
        <button
          type="button"
          onClick={copiar}
          title={`Chave de acesso: ${chave}\nClique para copiar`}
          className="text-[11px] font-mono text-zinc-600 hover:text-zinc-400 transition text-left"
        >
          {copiada ? "chave copiada" : `${chave.slice(0, 8)}…${chave.slice(-6)}`}
        </button>
      )}
    </span>
  )
}
