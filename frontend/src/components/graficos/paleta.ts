// A paleta dos gráficos, VALIDADA e não escolhida a olho.
//
// Os valores são a coluna escura da paleta de referência, conferidos com
// `scripts/validate_palette.js` contra a superfície real dos cartões (#18181b, o
// zinc-900) em 2026-09-30:
//
//   lightness, croma, separação para daltonismo, piso de visão normal e contraste
//   → TODOS PASSAM na lista de pares ADJACENTES, com 6 fatias.
//
// A ordem é o mecanismo de segurança, não enfeite: ela foi escolhida entre as que
// passam. Trocar a ordem exige rodar o validador de novo.
//
// LIMITE MEDIDO: em TODOS os pares (e não só nos vizinhos) nenhuma ordem passa além de
// três cores — o amarelo ao lado do laranja mede ΔE 4,8 para deuteranopia. Por isso as
// roscas trazem rótulo direto em cada fatia: a identidade nunca depende da cor sozinha.
export const SERIES = [
  "#3987e5", // 1 azul
  "#d95926", // 2 laranja
  "#199e70", // 3 verde-água
  "#c98500", // 4 amarelo
  "#d55181", // 5 magenta
  "#008300", // 6 verde
] as const

// Tinta e cromo, da mesma paleta de referência (coluna escura).
export const TINTA = {
  primaria: "#ffffff",
  secundaria: "#c3c2b7",
  apagada: "#898781",
  grade: "#2c2c2a",
  eixo: "#383835",
  superficie: "#18181b",
} as const

// A cor de uma fatia pela POSIÇÃO dela, nunca pelo tamanho.
//
// Cor segue a entidade: se um filtro mudar quem aparece, quem sobrou não pode trocar de
// cor — quem aprendeu "Shopee é laranja" seria enganado.
export function corDaSerie(indice: number): string {
  return SERIES[indice % SERIES.length]
}
