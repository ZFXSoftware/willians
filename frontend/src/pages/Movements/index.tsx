import { useState } from "react"
import { ArrowRightLeft, Play, Receipt, ShieldAlert } from "lucide-react"

import {
  pagar,
  transferir,
  type ResultadoMovimentacao,
} from "../../api/movimentacoes"
import { errorMessage } from "../../api/client"

// Os rótulos vêm do resumo do serviço; traduzir aqui evita o usuário ler
// nomes internos.
const RESULTADOS: Record<string, string> = {
  lancaria: "Seriam lançadas",
  lancadas: "Lançadas",
  baixaria: "Seriam baixados",
  baixados: "Baixados",
  divergente: "Com divergência (não baixados)",
  mesma_conta: "Origem igual ao destino",
  sem_nota: "Sem número de nota fiscal",
  titulo_nao_encontrado: "Sem título correspondente no OMIE",
  falhas: "Falharam",
}

export default function Movements() {
  return (
    <div className="space-y-6">
      <div>
        <p className="text-zinc-400 text-sm">Conciliação Financeira</p>
        <h1 className="text-3xl font-bold tracking-tight mt-1">Movimentações</h1>
        <p className="text-sm text-zinc-400 mt-2 max-w-2xl">
          Transferências do saldo das plataformas para a conta bancária e
          pagamentos de notas fiscais feitos direto no marketplace. Ambos
          gravam no OMIE — por isso começam sempre em simulação.
        </p>
      </div>

      <Acao
        Icone={ArrowRightLeft}
        titulo="Transferências entre contas"
        descricao="Cada saque do marketplace vira um lançamento de transferência no OMIE, da conta da plataforma para a conta bancária configurada."
        executar={transferir}
      />

      <Acao
        Icone={Receipt}
        titulo="Pagamentos feitos na plataforma"
        descricao="Pagamento de nota fiscal feito direto no marketplace é localizado no contas a pagar do OMIE e baixado. Valor que não confere não é baixado: vira divergência."
        executar={pagar}
      />
    </div>
  )
}

function Acao({
  Icone,
  titulo,
  descricao,
  executar,
}: {
  Icone: typeof ArrowRightLeft
  titulo: string
  descricao: string
  executar: (opcoes: { dryRun?: boolean }) => Promise<ResultadoMovimentacao>
}) {
  const [rodando, setRodando] = useState(false)
  const [resultado, setResultado] = useState<ResultadoMovimentacao | null>(null)
  const [aviso, setAviso] = useState<string | null>(null)

  async function rodar(dryRun: boolean) {
    setRodando(true)
    setAviso(null)

    try {
      setResultado(await executar({ dryRun }))
    } catch (e) {
      setResultado(null)
      setAviso(errorMessage(e, "Não foi possível executar"))
    } finally {
      setRodando(false)
    }
  }

  const simulou = resultado?.resumo?.simulacao === true

  const linhas = Object.entries(resultado?.resumo ?? {}).filter(
    ([chave, valor]) => chave !== "simulacao" && Number(valor) > 0,
  )

  return (
    <div className="bg-zinc-900 border border-zinc-800 rounded-3xl p-6 shadow-xl">
      <div className="flex items-start gap-4">
        <div className="w-12 h-12 rounded-2xl bg-white/5 border border-white/10 flex items-center justify-center text-zinc-300 shrink-0">
          <Icone size={20} />
        </div>

        <div className="min-w-0">
          <h2 className="font-semibold text-lg">{titulo}</h2>
          <p className="text-sm text-zinc-400 mt-1 max-w-2xl">{descricao}</p>
        </div>
      </div>

      <div className="mt-6 flex items-center gap-3 flex-wrap">
        <button
          onClick={() => rodar(true)}
          disabled={rodando}
          className="flex items-center gap-2 bg-zinc-800 hover:bg-zinc-700 disabled:opacity-40 px-5 py-2.5 rounded-xl text-sm font-medium transition"
        >
          <Play size={15} />
          Simular
        </button>

        <button
          onClick={() => rodar(false)}
          disabled={rodando}
          className="flex items-center gap-2 bg-emerald-600 hover:bg-emerald-500 disabled:opacity-40 px-5 py-2.5 rounded-xl text-sm font-medium transition"
        >
          Executar no OMIE
        </button>

        {rodando && <span className="text-sm text-zinc-400">executando...</span>}
      </div>

      {aviso && (
        <p className="mt-5 bg-red-500/10 border border-red-500/20 rounded-2xl px-4 py-3 text-sm text-red-300">
          {aviso}
        </p>
      )}

      {resultado && (
        <div className="mt-5 border-t border-zinc-800 pt-5 space-y-3">
          {simulou && (
            <p className="flex items-start gap-2 text-sm text-yellow-300 bg-yellow-500/10 border border-yellow-500/20 rounded-2xl px-4 py-3">
              <ShieldAlert size={16} className="mt-0.5 shrink-0" />
              Rodou em simulação — nada foi gravado no OMIE. A gravação depende
              de a escrita estar liberada no servidor.
            </p>
          )}

          {linhas.length === 0 ? (
            <p className="text-sm text-zinc-500">Nada a fazer neste período.</p>
          ) : (
            <div className="space-y-1.5">
              {linhas.map(([chave, valor]) => (
                <div key={chave} className="flex items-center justify-between gap-3 text-sm">
                  <span className="text-zinc-400">{RESULTADOS[chave] ?? chave}</span>
                  <span className="font-medium">{String(valor)}</span>
                </div>
              ))}
            </div>
          )}

          {resultado.detalhes.length > 0 && (
            <details className="text-sm">
              <summary className="cursor-pointer text-zinc-400 hover:text-white transition">
                Ver detalhe por lançamento ({resultado.detalhes.length})
              </summary>

              <div className="mt-3 space-y-1.5 max-h-72 overflow-y-auto">
                {resultado.detalhes.map((detalhe, i) => (
                  <p key={i} className="text-zinc-400 border-l-2 border-zinc-800 pl-3">
                    {detalhe.mensagem}
                  </p>
                ))}
              </div>
            </details>
          )}
        </div>
      )}
    </div>
  )
}
