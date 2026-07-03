import { Divergence } from "../../mocks/divergences";

interface Props {
  divergences: Divergence[];
}

const currency = (value: number) =>
  new Intl.NumberFormat("pt-BR", {
    style: "currency",
    currency: "BRL",
  }).format(value);

export function DivergenceCards({ divergences }: Props) {
  const open = divergences.filter((d) => d.status === "open").length;

  const resolved = divergences.filter(
    (d) => d.status === "resolved"
  ).length;

  const contesting = divergences.filter(
    (d) => d.status === "contesting"
  ).length;

  const critical = divergences.filter(
    (d) => d.status === "critical"
  ).length;

  const total = divergences.reduce(
    (sum, item) => sum + Math.abs(item.difference),
    0
  );

  const cards = [
    {
      title: "Abertas",
      value: open,
      color: "text-yellow-600",
      bg: "bg-yellow-50",
      border: "border-yellow-200",
      icon: "⚠️",
    },
    {
      title: "Resolvidas",
      value: resolved,
      color: "text-green-600",
      bg: "bg-green-50",
      border: "border-green-200",
      icon: "✅",
    },
    {
      title: "Em Contestação",
      value: contesting,
      color: "text-blue-600",
      bg: "bg-blue-50",
      border: "border-blue-200",
      icon: "💬",
    },
    {
      title: "Críticas",
      value: critical,
      color: "text-red-600",
      bg: "bg-red-50",
      border: "border-red-200",
      icon: "🚨",
    },
  ];

  return (
    <>
      <div className="grid gap-6 lg:grid-cols-4">

        {cards.map((card) => (
          <div
            key={card.title}
            className={`rounded-xl border ${card.border} ${card.bg} p-6 shadow-sm transition hover:shadow-md`}
          >
            <div className="flex items-center justify-between">

              <div>

                <p className="text-sm text-slate-500">
                  {card.title}
                </p>

                <h2
                  className={`mt-2 text-4xl font-bold ${card.color}`}
                >
                  {card.value}
                </h2>

              </div>

              <div className="text-4xl">
                {card.icon}
              </div>

            </div>
          </div>
        ))}

      </div>

      <div className="mt-6 rounded-xl border border-slate-200 bg-white p-6 shadow-sm">

        <div className="flex items-center justify-between">

          <div>

            <p className="text-sm text-slate-500">
              Valor Total Divergente
            </p>

            <h2 className="mt-2 text-4xl font-bold text-red-600">
              {currency(total)}
            </h2>

          </div>

          <div className="rounded-full bg-red-100 p-5 text-5xl">
            💰
          </div>

        </div>

        <div className="mt-6 h-2 overflow-hidden rounded-full bg-slate-100">

          <div
            className="h-full rounded-full bg-red-500"
            style={{
              width: `${Math.min(
                (total / 1000) * 100,
                100
              )}%`,
            }}
          />

        </div>

        <div className="mt-3 flex justify-between text-sm text-slate-500">

          <span>
            Impacto financeiro acumulado
          </span>

          <span>
            {divergences.length} registros
          </span>

        </div>

      </div>
    </>
  );
}