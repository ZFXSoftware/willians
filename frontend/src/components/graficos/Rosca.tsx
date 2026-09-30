import { useState } from "react"

import { corDaSerie, TINTA } from "./paleta"

// Rosca (pizza com furo), para parte-e-todo.
//
// Só serve quando as partes SOMAM o todo e são poucas. Com muitas fatias, ou para
// comparar valores próximos, a rosca mente — e aí a resposta é uma lista de números.
//
// Cada fatia traz o RÓTULO DIRETO ao lado do valor. Isso não é enfeite: em todos os
// pares, nenhuma ordem de cores passa nos pisos de daltonismo além de três fatias
// (amarelo ao lado de laranja mede ΔE 4,8 para deuteranopia). Com rótulo, a identidade
// nunca depende da cor.

export interface FatiaDaRosca {
  rotulo: string
  valor: number
}

const TAMANHO = 180
const RAIO = 78
const FURO = 48

export default function Rosca({
  fatias,
  formatar,
  vazio = "Sem dados no período.",
}: {
  fatias: FatiaDaRosca[]
  formatar: (valor: number) => string
  vazio?: string
}) {
  const [ativa, setAtiva] = useState<number | null>(null)

  const positivas = fatias.filter((f) => f.valor > 0)

  const total = positivas.reduce((soma, f) => soma + f.valor, 0)

  if (total <= 0) {
    return <p className="text-sm text-zinc-500 py-8 text-center">{vazio}</p>
  }

  // Uma fatia só não é gráfico: o número é a resposta.
  if (positivas.length === 1) {
    return (
      <div className="py-6 text-center">
        <p className="text-2xl font-semibold text-zinc-100">{formatar(positivas[0].valor)}</p>
        <p className="text-sm text-zinc-400 mt-1">{positivas[0].rotulo}</p>
      </div>
    )
  }

  let anguloCorrente = -Math.PI / 2

  const arcos = positivas.map((fatia, indice) => {
    const fracao = fatia.valor / total
    const inicio = anguloCorrente
    const fim = inicio + fracao * Math.PI * 2

    anguloCorrente = fim

    return { fatia, indice, inicio, fim, fracao }
  })

  const ponto = (angulo: number, raio: number) => [
    TAMANHO / 2 + Math.cos(angulo) * raio,
    TAMANHO / 2 + Math.sin(angulo) * raio,
  ]

  return (
    <div className="flex flex-col sm:flex-row items-center gap-6">
      <svg
        viewBox={`0 0 ${TAMANHO} ${TAMANHO}`}
        style={{ width: TAMANHO, height: TAMANHO }}
        className="shrink-0"
        role="img"
        onMouseLeave={() => setAtiva(null)}
      >
        {arcos.map(({ fatia, indice, inicio, fim }) => {
          const [x1, y1] = ponto(inicio, RAIO)
          const [x2, y2] = ponto(fim, RAIO)
          const [x3, y3] = ponto(fim, FURO)
          const [x4, y4] = ponto(inicio, FURO)

          const grande = fim - inicio > Math.PI ? 1 : 0

          return (
            <path
              key={fatia.rotulo}
              d={`M ${x1} ${y1} A ${RAIO} ${RAIO} 0 ${grande} 1 ${x2} ${y2} L ${x3} ${y3} A ${FURO} ${FURO} 0 ${grande} 0 ${x4} ${y4} Z`}
              fill={corDaSerie(indice)}
              /* Vão de 2px na cor da superfície entre fatias, em vez de borda em volta
                 delas: separa sem sujar o desenho. */
              stroke={TINTA.superficie}
              strokeWidth={2}
              opacity={ativa === null || ativa === indice ? 1 : 0.35}
              onMouseEnter={() => setAtiva(indice)}
              style={{ transition: "opacity 120ms" }}
            />
          )
        })}

        <text
          x={TAMANHO / 2}
          y={TAMANHO / 2 - 4}
          textAnchor="middle"
          fontSize={11}
          fill={TINTA.apagada}
        >
          {ativa === null ? "total" : `${Math.round(arcos[ativa].fracao * 100)}%`}
        </text>
        <text
          x={TAMANHO / 2}
          y={TAMANHO / 2 + 12}
          textAnchor="middle"
          fontSize={13}
          fill={TINTA.primaria}
          fontWeight={600}
        >
          {formatar(ativa === null ? total : arcos[ativa].fatia.valor)}
        </text>
      </svg>

      {/* Legenda com RÓTULO e VALOR em cada linha: é ela que carrega a identidade quando
          a cor não dá conta. */}
      <ul className="flex-1 w-full space-y-1.5 min-w-0">
        {arcos.map(({ fatia, indice, fracao }) => (
          <li
            key={fatia.rotulo}
            className="flex items-center gap-2 text-sm cursor-default"
            onMouseEnter={() => setAtiva(indice)}
            onMouseLeave={() => setAtiva(null)}
          >
            <span
              className="w-2.5 h-2.5 rounded-full shrink-0"
              style={{ background: corDaSerie(indice) }}
            />
            <span className="text-zinc-300 truncate">{fatia.rotulo}</span>
            <span className="text-zinc-500 text-xs tabular-nums ml-auto shrink-0">
              {Math.round(fracao * 100)}%
            </span>
            <span className="text-zinc-100 tabular-nums shrink-0 w-24 text-right">
              {formatar(fatia.valor)}
            </span>
          </li>
        ))}
      </ul>
    </div>
  )
}
