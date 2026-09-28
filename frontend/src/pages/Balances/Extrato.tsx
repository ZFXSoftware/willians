import { useState } from "react"
import { AlertTriangle, ListOrdered } from "lucide-react"

import {
  fetchExtrato,
  type LinhaDoExtrato,
  type MovimentoPorTipo,
  type SaldoDaConta,
} from "../../api/saldos"
import { useResource } from "../../hooks/useResource"
import { brl, dataHoraBR, rotulo } from "../../lib/format"
import { Carregando, ErroAoCarregar, Vazio } from "../../components/Estados"

// "Na conta virtual Disponível −R$ 24.946,11, como assim?"
//
// Saldo negativo numa conta real é impossível, e a tela mostrava só o número. Descobrir
// de onde vinha custou uma sequência de scripts, e a resposta era uma linha de extrato.
// Esta tela responde sozinha.
//
// A coluna que torna isso possível é a do MARKETPLACE: `BALANCE_AMOUNT` é o saldo
// corrente que ele mantém, fonte independente da nossa. Onde os dois se separam está o
// movimento que falta ou que sobra — e é um movimento, não um total.
export default function Extrato({ contas }: { contas: SaldoDaConta[] }) {
  const [contaId, setContaId] = useState<number | undefined>(contas[0]?.platform_account_id)

  const { data, loading, error, reload } = useResource(() => fetchExtrato(contaId), [contaId])

  return (
    <div className="bg-zinc-900 border border-zinc-800 rounded-3xl p-6 shadow-xl">
      <div className="flex items-start justify-between gap-4 flex-wrap">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 rounded-2xl bg-white/5 border border-white/10 flex items-center justify-center text-zinc-300">
            <ListOrdered size={18} />
          </div>

          <div>
            <h3 className="font-semibold text-lg">Extrato da conta virtual</h3>
            <p className="text-sm text-zinc-400 mt-0.5">
              Cada linha do relatório, com o nosso saldo ao lado do saldo da plataforma.
            </p>
          </div>
        </div>

        {contas.length > 1 && (
          <select
            value={contaId ?? ""}
            onChange={(e) => setContaId(Number(e.target.value))}
            className="bg-zinc-950 border border-zinc-800 rounded-xl px-3 py-2 text-sm"
          >
            {contas.map((c) => (
              <option key={c.platform_account_id} value={c.platform_account_id}>
                {c.nome} · {rotulo(c.plataforma)}
              </option>
            ))}
          </select>
        )}
      </div>

      {loading && <Carregando texto="Montando o extrato..." />}

      {error && <ErroAoCarregar mensagem={error} onRetry={reload} />}

      {data && data.total_de_linhas === 0 && (
        <Vazio
          titulo="Nenhum movimento"
          descricao="Esta conta ainda não tem lançamentos no razão."
        />
      )}

      {data && data.total_de_linhas > 0 && (
        <>
          {/* A resposta para "como o saldo chegou aqui", quando existe. Vem ANTES da
              lista: quem abre a tela com essa pergunta não deveria ter que rolar. */}
          {data.primeira_divergencia && (
            <Divergencia linha={data.primeira_divergencia} />
          )}

          {/* A conta que responde "o dinheiro chegou?", e que até agora não existia
              porque a primeira parcela não existia. O saldo inicial é deduzido do saldo
              que a plataforma informa na primeira linha. */}
          <div className="mt-6 grid grid-cols-2 lg:grid-cols-4 gap-3">
            <Parcela titulo="Saldo antes do primeiro movimento" valor={data.saldo_inicial} />
            <Parcela titulo="Entrou" valor={soma(data.por_tipo, "credito")} tom="text-emerald-400" />
            <Parcela titulo="Saiu" valor={soma(data.por_tipo, "debito")} tom="text-red-400" />
            <Parcela titulo="Disponível hoje" valor={data.saldo.available_balance} />
          </div>

          <div className="mt-6">
            <p className="text-xs uppercase tracking-wide text-zinc-500">
              Por tipo de movimento
            </p>

            <div className="mt-3 overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="text-left text-zinc-500 border-b border-zinc-800">
                    <th className="py-2 pr-4 font-medium">Movimento</th>
                    <th className="py-2 px-4 font-medium text-right">Linhas</th>
                    <th className="py-2 px-4 font-medium text-right">Entrou</th>
                    <th className="py-2 px-4 font-medium text-right">Saiu</th>
                    <th className="py-2 px-4 font-medium text-right">Resultado</th>
                    <th className="py-2 pl-4 font-medium text-right">Pendentes</th>
                  </tr>
                </thead>
                <tbody>
                  {data.por_tipo.map((tipo) => (
                    <tr key={tipo.movimento} className="border-b border-zinc-800/60">
                      <td className="py-2 pr-4">{tipo.movimento}</td>
                      <td className="py-2 px-4 text-right text-zinc-400">{tipo.quantidade}</td>
                      <td className="py-2 px-4 text-right text-emerald-400">
                        {Number(tipo.credito) ? brl(tipo.credito) : "—"}
                      </td>
                      <td className="py-2 px-4 text-right text-red-400">
                        {Number(tipo.debito) ? brl(tipo.debito) : "—"}
                      </td>
                      <td
                        className={`py-2 px-4 text-right font-medium ${
                          Number(tipo.resultado) < 0 ? "text-red-300" : "text-zinc-200"
                        }`}
                      >
                        {brl(tipo.resultado)}
                      </td>
                      {/* Lançamento não liquidado não entra no disponível. Um tipo com
                          saída liquidada e entrada pendente deixa o saldo negativo sem
                          nada estar errado no dinheiro. */}
                      <td className="py-2 pl-4 text-right">
                        {tipo.pendentes ? (
                          <span className="text-amber-400">{tipo.pendentes}</span>
                        ) : (
                          <span className="text-zinc-600">—</span>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </div>

          <div className="mt-8">
            <div className="flex items-center justify-between gap-3 flex-wrap">
              <p className="text-xs uppercase tracking-wide text-zinc-500">
                Movimentos, do mais recente
              </p>
              <p className="text-xs text-zinc-600">
                {data.linhas.length} de {data.total_de_linhas}
              </p>
            </div>

            <div className="mt-3 overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="text-left text-zinc-500 border-b border-zinc-800">
                    <th className="py-2 pr-4 font-medium">Quando</th>
                    <th className="py-2 px-4 font-medium">Movimento</th>
                    <th className="py-2 px-4 font-medium">Pedido</th>
                    <th className="py-2 px-4 font-medium text-right">Valor</th>
                    <th className="py-2 px-4 font-medium text-right">Saldo aqui</th>
                    <th className="py-2 px-4 font-medium text-right">Saldo na plataforma</th>
                    <th className="py-2 pl-4 font-medium text-right">Distância</th>
                  </tr>
                </thead>
                <tbody>
                  {data.linhas.map((linha) => (
                    <Linha key={`${linha.referencia}-${linha.ocorrido_em}`} linha={linha} />
                  ))}
                </tbody>
              </table>
            </div>
          </div>
        </>
      )}
    </div>
  )
}

function soma(tipos: MovimentoPorTipo[], campo: "credito" | "debito"): string {
  return tipos.reduce((total, t) => total + Number(t[campo]), 0).toFixed(2)
}

function Parcela({ titulo, valor, tom }: { titulo: string; valor: string; tom?: string }) {
  return (
    <div className="bg-zinc-950/60 border border-zinc-800 rounded-2xl p-4">
      <p className="text-xs text-zinc-500">{titulo}</p>
      <p className={`text-lg font-semibold mt-1.5 ${tom ?? "text-zinc-200"}`}>{brl(valor)}</p>
    </div>
  )
}

function Divergencia({ linha }: { linha: LinhaDoExtrato & { salto: string } }) {
  return (
    <div className="mt-6 rounded-2xl border border-amber-500/30 bg-amber-500/5 p-5">
      <div className="flex items-start gap-3">
        <AlertTriangle size={18} className="text-amber-400 mt-0.5 shrink-0" />

        <div className="min-w-0">
          <p className="font-medium text-amber-200">
            O saldo se separou do da plataforma neste movimento
          </p>

          <p className="text-sm text-zinc-300 mt-2">
            Em {dataHoraBR(linha.ocorrido_em)}, no movimento{" "}
            <span className="font-medium">{linha.movimento}</span>
            {linha.pedido && <> do pedido {linha.pedido}</>}, o nosso razão ficou em{" "}
            <span className="font-medium">{brl(linha.saldo_nosso)}</span> e a plataforma em{" "}
            <span className="font-medium">{brl(linha.saldo_deles ?? "0")}</span> — um salto
            de <span className="font-medium">{brl(linha.salto)}</span>.
          </p>

          {/* Depois da primeira, todas divergem: o erro é cumulativo. Dizer isso evita
              que alguém tente consertar as outras uma por uma. */}
          <p className="text-xs text-zinc-500 mt-3">
            Daqui para frente todos os saldos ficam distantes, porque a diferença se
            acumula. É este movimento que precisa ser olhado, não os seguintes.
            {Number(linha.salto) < 0
              ? " Saldo menor aqui: há crédito que não entrou no nosso razão."
              : " Saldo maior aqui: há débito que a plataforma registrou e nós não."}
          </p>
        </div>
      </div>
    </div>
  )
}

function Linha({ linha }: { linha: LinhaDoExtrato }) {
  const distancia = linha.distancia === null ? null : Number(linha.distancia)

  return (
    <tr className="border-b border-zinc-800/60">
      <td className="py-2 pr-4 text-zinc-400 whitespace-nowrap">
        {dataHoraBR(linha.ocorrido_em)}
      </td>
      <td className="py-2 px-4">
        {linha.movimento}
        {linha.lancamentos > 1 && (
          <span className="text-zinc-600 text-xs"> · {linha.lancamentos} lançamentos</span>
        )}
        {linha.pendentes > 0 && (
          <span className="text-amber-400 text-xs"> · {linha.pendentes} pendente(s)</span>
        )}
      </td>
      <td className="py-2 px-4 text-zinc-500 font-mono text-xs">{linha.pedido ?? "—"}</td>
      <td
        className={`py-2 px-4 text-right font-medium ${
          Number(linha.valor) < 0 ? "text-red-300" : "text-emerald-300"
        }`}
      >
        {Number(linha.valor) > 0 ? "+" : ""}
        {brl(linha.valor)}
      </td>
      <td className="py-2 px-4 text-right">{brl(linha.saldo_nosso)}</td>
      <td className="py-2 px-4 text-right text-zinc-400">
        {linha.saldo_deles ? brl(linha.saldo_deles) : "—"}
      </td>
      <td className="py-2 pl-4 text-right">
        {distancia === null ? (
          <span className="text-zinc-600">—</span>
        ) : Math.abs(distancia) < 0.1 ? (
          <span className="text-emerald-400">confere</span>
        ) : (
          <span className="text-amber-400">{brl(linha.distancia ?? "0")}</span>
        )}
      </td>
    </tr>
  )
}
