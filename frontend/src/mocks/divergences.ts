export type DivergenceStatus =
  | "open"
  | "resolved"
  | "contesting"
  | "critical";

export interface Divergence {
  id: number;
  order: number;
  invoice: number;
  customer: string;
  platform: string;
  expected: number;
  received: number;
  difference: number;
  reason: string;
  status: DivergenceStatus;
  createdAt: string;
}

export const mockDivergences: Divergence[] = [
  {
    id: 1,
    order: 84521,
    invoice: 3215,
    customer: "João da Silva",
    platform: "Mercado Livre",
    expected: 158.9,
    received: 153.9,
    difference: -5,
    reason: "Taxa superior à prevista",
    status: "open",
    createdAt: "2026-07-02",
  },
  {
    id: 2,
    order: 84522,
    invoice: 3216,
    customer: "Maria Oliveira",
    platform: "Shopee",
    expected: 278.4,
    received: 0,
    difference: -278.4,
    reason: "Repasse não realizado",
    status: "critical",
    createdAt: "2026-07-01",
  },
  {
    id: 3,
    order: 84523,
    invoice: 3217,
    customer: "Carlos Souza",
    platform: "Amazon",
    expected: 810,
    received: 817.5,
    difference: 7.5,
    reason: "Crédito complementar",
    status: "resolved",
    createdAt: "2026-07-03",
  },
  {
    id: 4,
    order: 84524,
    invoice: 3218,
    customer: "Fernanda Lima",
    platform: "Mercado Livre",
    expected: 92.9,
    received: 88.9,
    difference: -4,
    reason: "Diferença de tarifa",
    status: "contesting",
    createdAt: "2026-06-29",
  },
  {
    id: 5,
    order: 84525,
    invoice: 3219,
    customer: "Lucas Andrade",
    platform: "Shopee",
    expected: 456,
    received: 450,
    difference: -6,
    reason: "Desconto inesperado",
    status: "open",
    createdAt: "2026-07-03",
  },
  {
    id: 6,
    order: 84526,
    invoice: 3220,
    customer: "Patrícia Gomes",
    platform: "Amazon",
    expected: 329.99,
    received: 329.99,
    difference: 0,
    reason: "Ajuste concluído",
    status: "resolved",
    createdAt: "2026-07-01",
  },
  {
    id: 7,
    order: 84527,
    invoice: 3221,
    customer: "Ricardo Alves",
    platform: "Magalu",
    expected: 127,
    received: 115,
    difference: -12,
    reason: "Taxa logística",
    status: "critical",
    createdAt: "2026-07-02",
  },
  {
    id: 8,
    order: 84528,
    invoice: 3222,
    customer: "Amanda Rocha",
    platform: "Mercado Livre",
    expected: 620,
    received: 615,
    difference: -5,
    reason: "Contestação enviada",
    status: "contesting",
    createdAt: "2026-07-03",
  },
];