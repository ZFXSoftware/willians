import { useEffect, useState } from "react"
import { Search } from "lucide-react"

import { opcoesOmie, type OpcaoOmie, type TipoOpcaoOmie } from "../api/integracoes"

// Escolhe um cadastro do OMIE pelo NOME, e guarda o código.
//
// Antes isto era um campo de texto com a instrução "obtenha em ListarClientes"
// — ou seja, abra um terminal, rode uma tarefa, copie um número. Funciona para
// quem tem acesso ao servidor, e não para quem opera o sistema. Com vários
// clientes, funciona para ninguém.
//
// Busca em vez de lista fechada porque a conta do cliente tem milhares de
// cadastros: uma lista dessas na tela é tão inútil quanto não ter lista.
export function EscolhaDoOmie({
  tipo,
  valor,
  placeholder,
  aoEscolher,
}: {
  tipo: TipoOpcaoOmie
  valor: string
  placeholder?: string
  aoEscolher: (codigo: string) => void
}) {
  const [busca, setBusca] = useState("")
  const [itens, setItens] = useState<OpcaoOmie[]>([])
  const [aberto, setAberto] = useState(false)
  const [carregando, setCarregando] = useState(false)
  const [erro, setErro] = useState<string | null>(null)

  // Espera a digitação parar antes de perguntar ao OMIE: uma consulta por
  // tecla estouraria o limite de requisições deles em poucos segundos.
  useEffect(() => {
    if (!aberto) return

    const id = setTimeout(async () => {
      setCarregando(true)
      setErro(null)

      try {
        setItens(await opcoesOmie(tipo, busca || undefined))
      } catch (e: any) {
        setErro(e?.response?.data?.error ?? "Não foi possível consultar o OMIE")
      } finally {
        setCarregando(false)
      }
    }, 400)

    return () => clearTimeout(id)
  }, [busca, aberto, tipo])

  return (
    <div>
      <div className="flex gap-2">
        <input
          value={valor}
          onChange={(e) => aoEscolher(e.target.value)}
          placeholder={placeholder}
          className="flex-1 bg-zinc-950 border border-zinc-800 rounded-xl px-3 py-2 text-sm"
        />

        <button
          type="button"
          onClick={() => setAberto(!aberto)}
          className="flex items-center gap-2 bg-zinc-800 hover:bg-zinc-700 px-3 py-2 rounded-xl text-sm transition shrink-0"
        >
          <Search size={14} />
          {aberto ? "Fechar" : "Procurar"}
        </button>
      </div>

      {aberto && (
        <div className="mt-2 border border-zinc-800 rounded-xl overflow-hidden">
          <input
            autoFocus
            value={busca}
            onChange={(e) => setBusca(e.target.value)}
            placeholder="Digite parte do nome"
            className="w-full bg-zinc-950 px-3 py-2 text-sm border-b border-zinc-800 outline-none"
          />

          <div className="max-h-56 overflow-y-auto">
            {erro && <p className="px-3 py-2 text-xs text-red-400">{erro}</p>}

            {!erro && carregando && (
              <p className="px-3 py-2 text-xs text-zinc-500">Consultando o OMIE...</p>
            )}

            {!erro && !carregando && itens.length === 0 && (
              <p className="px-3 py-2 text-xs text-zinc-500">
                Nada encontrado. Tente outra parte do nome.
              </p>
            )}

            {!carregando &&
              itens.map((item) => (
                <button
                  key={item.codigo}
                  type="button"
                  onClick={() => {
                    aoEscolher(item.codigo)
                    setAberto(false)
                  }}
                  className="w-full text-left px-3 py-2 text-sm hover:bg-zinc-800/60 transition flex justify-between gap-3"
                >
                  <span className="truncate">{item.nome}</span>
                  <span className="text-zinc-500 shrink-0">{item.codigo}</span>
                </button>
              ))}
          </div>
        </div>
      )}
    </div>
  )
}
