import { Divergence } from "../../mocks/divergences";

interface Props {
  divergences: Divergence[];
  onSelect: (divergence: Divergence) => void;
}

const statusConfig = {
  open: {
    label: "Aberta",
    className: "bg-yellow-100 text-yellow-800",
  },
  resolved: {
    label: "Resolvida",
    className: "bg-green-100 text-green-800",
  },
  contesting: {
    label: "Contestação",
    className: "bg-blue-100 text-blue-800",
  },
  critical: {
    label: "Crítica",
    className: "bg-red-100 text-red-800",
  },
};

const currency = (value: number) =>
  new Intl.NumberFormat("pt-BR", {
    style: "currency",
    currency: "BRL",
  }).format(value);

export function DivergenceTable({
  divergences,
  onSelect,
}: Props) {
  return (
    <div className="overflow-x-auto">

      <table className="min-w-full divide-y divide-slate-200">

        <thead className="bg-slate-50">

          <tr>

            <th className="px-6 py-4 text-left text-xs font-semibold uppercase tracking-wide text-slate-500">
              Pedido
            </th>

            <th className="px-6 py-4 text-left text-xs font-semibold uppercase tracking-wide text-slate-500">
              NF
            </th>

            <th className="px-6 py-4 text-left text-xs font-semibold uppercase tracking-wide text-slate-500">
              Cliente
            </th>

            <th className="px-6 py-4 text-left text-xs font-semibold uppercase tracking-wide text-slate-500">
              Plataforma
            </th>

            <th className="px-6 py-4 text-right text-xs font-semibold uppercase tracking-wide text-slate-500">
              Esperado
            </th>

            <th className="px-6 py-4 text-right text-xs font-semibold uppercase tracking-wide text-slate-500">
              Recebido
            </th>

            <th className="px-6 py-4 text-right text-xs font-semibold uppercase tracking-wide text-slate-500">
              Diferença
            </th>

            <th className="px-6 py-4 text-center text-xs font-semibold uppercase tracking-wide text-slate-500">
              Status
            </th>

            <th className="px-6 py-4"></th>

          </tr>

        </thead>

        <tbody className="divide-y divide-slate-100 bg-white">

          {divergences.map((item) => {

            const status = statusConfig[item.status];

            return (
              <tr
                key={item.id}
                className="cursor-pointer transition hover:bg-slate-50"
                onClick={() => onSelect(item)}
              >
                <td className="px-6 py-4 font-medium text-slate-900">
                  #{item.order}
                </td>

                <td className="px-6 py-4">
                  {item.invoice}
                </td>

                <td className="px-6 py-4">
                  {item.customer}
                </td>

                <td className="px-6 py-4">
                  {item.platform}
                </td>

                <td className="px-6 py-4 text-right">
                  {currency(item.expected)}
                </td>

                <td className="px-6 py-4 text-right">
                  {currency(item.received)}
                </td>

                <td
                  className={`px-6 py-4 text-right font-semibold ${
                    item.difference < 0
                      ? "text-red-600"
                      : "text-green-600"
                  }`}
                >
                  {currency(item.difference)}
                </td>

                <td className="px-6 py-4 text-center">

                  <span
                    className={`inline-flex rounded-full px-3 py-1 text-xs font-semibold ${status.className}`}
                  >
                    {status.label}
                  </span>

                </td>

                <td className="px-6 py-4 text-right">

                  <button
                    onClick={(e) => {
                      e.stopPropagation();
                      onSelect(item);
                    }}
                    className="rounded-lg border border-slate-200 px-3 py-2 text-sm transition hover:bg-slate-100"
                  >
                    Visualizar
                  </button>

                </td>

              </tr>
            );
          })}

        </tbody>

      </table>

      {divergences.length === 0 && (
        <div className="flex h-56 items-center justify-center text-slate-500">
          Nenhuma divergência encontrada.
        </div>
      )}

    </div>
  );
}