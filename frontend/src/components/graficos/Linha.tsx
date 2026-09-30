import { useState } from "react"

import { corDaSerie, TINTA } from "./paleta"

// Gráfico de linha em SVG, com mira e balão ao passar o mouse.
//
// Sem biblioteca: são duas séries numa escala só, e trazer um pacote de gráficos para
// isso custaria mais em peso de página do que o arquivo inteiro.
//
// UMA escala de valor, sempre. Duas escalas no mesmo desenho inventam uma correlação que
// não está no dado — é o erro de gráfico mais comum que existe. Quando as séries têm
// unidades diferentes (dinheiro e contagem), são DOIS gráficos.

export interface PontoDaSerie {
  x: string
  y: number
}

export interface SerieDeLinha {
  nome: string
  pontos: PontoDaSerie[]
}

const ALTURA = 220
const MARGEM = { topo: 16, direita: 16, base: 28, esquerda: 64 }

export default function Linha({
  series,
  formatar,
  rotuloDoX,
}: {
  series: SerieDeLinha[]
  formatar: (valor: number) => string
  rotuloDoX: (x: string) => string
}) {
  const [ativo, setAtivo] = useState<number | null>(null)

  const largura = 900
  const plotW = largura - MARGEM.esquerda - MARGEM.direita
  const plotH = ALTURA - MARGEM.topo - MARGEM.base

  const pontos = series[0]?.pontos ?? []

  if (pontos.length === 0) {
    return <p className="text-sm text-zinc-500 py-8 text-center">Sem dados no período.</p>
  }

  // O topo da escala vem do MAIOR valor de todas as séries: escalas diferentes por série
  // seriam o eixo duplo disfarçado.
  const maximo = Math.max(1, ...series.flatMap((s) => s.pontos.map((p) => p.y)))

  const x = (i: number) => MARGEM.esquerda + (pontos.length === 1 ? plotW / 2 : (i / (pontos.length - 1)) * plotW)
  const y = (v: number) => MARGEM.topo + plotH - (v / maximo) * plotH

  // Quatro linhas de grade: mais que isso vira gaiola, e a grade é pano de fundo.
  const marcas = [0, 0.25, 0.5, 0.75, 1].map((f) => f * maximo)

  // Rótulos do eixo X ralos de propósito: 90 datas não cabem, e um eixo ilegível é pior
  // que um eixo esparso.
  const passo = Math.max(1, Math.ceil(pontos.length / 8))

  return (
    <div className="relative">
      {/* Legenda SEMPRE, a partir de duas séries. Com uma só, o título do cartão já a
          nomeia e uma caixa de legenda seria ruído. */}
      {series.length > 1 && (
        <ul className="flex flex-wrap gap-x-5 gap-y-1 mb-2">
          {series.map((serie, indice) => (
            <li key={serie.nome} className="flex items-center gap-2 text-xs text-zinc-400">
              <span
                className="w-2.5 h-2.5 rounded-full shrink-0"
                style={{ background: corDaSerie(indice) }}
              />
              {serie.nome}
            </li>
          ))}
        </ul>
      )}

      <svg
        viewBox={`0 0 ${largura} ${ALTURA}`}
        className="w-full"
        style={{ height: ALTURA }}
        role="img"
        onMouseLeave={() => setAtivo(null)}
      >
        {marcas.map((valor, i) => (
          <g key={i}>
            {/* Grade em traço CONTÍNUO e fino: tracejado lê como projeção ou limite,
                quando é só grade. */}
            <line
              x1={MARGEM.esquerda}
              x2={largura - MARGEM.direita}
              y1={y(valor)}
              y2={y(valor)}
              stroke={i === 0 ? TINTA.eixo : TINTA.grade}
              strokeWidth={1}
            />
            <text
              x={MARGEM.esquerda - 8}
              y={y(valor) + 4}
              textAnchor="end"
              fontSize={11}
              fill={TINTA.apagada}
              style={{ fontVariantNumeric: "tabular-nums" }}
            >
              {formatar(valor)}
            </text>
          </g>
        ))}

        {pontos.map((ponto, i) =>
          i % passo === 0 ? (
            <text
              key={ponto.x}
              x={x(i)}
              y={ALTURA - 8}
              textAnchor="middle"
              fontSize={11}
              fill={TINTA.apagada}
            >
              {rotuloDoX(ponto.x)}
            </text>
          ) : null,
        )}

        {/* Rótulo DIRETO no PICO de cada série, além da legenda.
            
            Era no último ponto, e no dado real o último dia da janela é HOJE — ainda sem
            venda e sem saque. Os dois rótulos saíam "0", empilhados em cima do eixo e
            ilegíveis. O pico responde algo ("o melhor dia foram R$ 18 mil"); o fim da
            janela não respondia nada. */}
        {series.length > 1 &&
          series.map((serie, indice) => {
            if (serie.pontos.length === 0) return null

            const pico = serie.pontos.reduce(
              (melhor, ponto, i) => (ponto.y > serie.pontos[melhor].y ? i : melhor),
              0,
            )

            if (serie.pontos[pico].y <= 0) return null

            // Encostado na borda o texto sai do desenho: ali ele ancora para dentro.
            const perto_do_fim = pico > serie.pontos.length - 8

            return (
              <text
                key={`pico-${serie.nome}`}
                x={x(pico) + (perto_do_fim ? -6 : 6)}
                y={y(serie.pontos[pico].y) - 8}
                textAnchor={perto_do_fim ? "end" : "start"}
                fontSize={11}
                fill={corDaSerie(indice)}
                fontWeight={600}
              >
                {formatar(serie.pontos[pico].y)}
              </text>
            )
          })}

        {series.map((serie, indice) => (
          <polyline
            key={serie.nome}
            fill="none"
            stroke={corDaSerie(indice)}
            strokeWidth={2}
            strokeLinejoin="round"
            strokeLinecap="round"
            points={serie.pontos.map((p, i) => `${x(i)},${y(p.y)}`).join(" ")}
          />
        ))}

        {/* A mira e os marcadores do ponto sob o cursor. O anel na cor da superfície
            separa marcadores que se sobrepõem sem desenhar borda em volta deles. */}
        {ativo !== null && (
          <g>
            <line
              x1={x(ativo)}
              x2={x(ativo)}
              y1={MARGEM.topo}
              y2={MARGEM.topo + plotH}
              stroke={TINTA.eixo}
              strokeWidth={1}
            />
            {series.map((serie, indice) => (
              <circle
                key={serie.nome}
                cx={x(ativo)}
                cy={y(serie.pontos[ativo]?.y ?? 0)}
                r={4}
                fill={corDaSerie(indice)}
                stroke={TINTA.superficie}
                strokeWidth={2}
              />
            ))}
          </g>
        )}

        {/* Faixas invisíveis de captura: o alvo do mouse é bem maior que o marcador,
            senão acertar um ponto de 4px vira perícia. */}
        {pontos.map((ponto, i) => (
          <rect
            key={ponto.x}
            x={x(i) - plotW / pontos.length / 2}
            y={MARGEM.topo}
            width={plotW / pontos.length}
            height={plotH}
            fill="transparent"
            onMouseEnter={() => setAtivo(i)}
          />
        ))}
      </svg>

      {ativo !== null && (
        <div
          className="absolute top-2 pointer-events-none bg-zinc-950/95 border border-zinc-700 rounded-xl px-3 py-2 text-xs shadow-2xl"
          style={{
            left: `${(x(ativo) / largura) * 100}%`,
            transform: x(ativo) > largura / 2 ? "translateX(-105%)" : "translateX(5%)",
          }}
        >
          <p className="text-zinc-400">{rotuloDoX(pontos[ativo].x)}</p>

          {series.map((serie, indice) => (
            <p key={serie.nome} className="flex items-center gap-2 mt-1">
              <span
                className="w-2 h-2 rounded-full shrink-0"
                style={{ background: corDaSerie(indice) }}
              />
              {/* O texto fica em tinta neutra; a cor identifica pelo ponto ao lado. */}
              <span className="text-zinc-400">{serie.nome}</span>
              <span className="text-zinc-100 font-medium ml-auto tabular-nums">
                {formatar(serie.pontos[ativo]?.y ?? 0)}
              </span>
            </p>
          ))}
        </div>
      )}
    </div>
  )
}
