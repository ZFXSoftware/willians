export default function ReconciliationDashboard() {
  const stats = [
    {
      title: 'Total Conciliado',
      value: 'R$ 248.920,33',
      change: '+12.4%',
    },
    {
      title: 'Divergências',
      value: '17',
      change: '-3 hoje',
    },
    {
      title: 'Recebimentos Futuros',
      value: 'R$ 89.332,10',
      change: 'Próx. 30 dias',
    },
    {
      title: 'Saldo Virtual',
      value: 'R$ 32.440,88',
      change: 'Atualizado agora',
    },
  ]

  const rows = [
    {
      status: 'Conciliado',
      pedido: '#ML-90231',
      nf: 'NF-10029',
      plataforma: 'Mercado Livre',
      esperado: 'R$ 1.240,00',
      recebido: 'R$ 1.240,00',
      diferenca: 'R$ 0,00',
      data: '09/05/2026',
    },
    {
      status: 'Divergente',
      pedido: '#SP-11382',
      nf: 'NF-10030',
      plataforma: 'Shopee',
      esperado: 'R$ 820,00',
      recebido: 'R$ 793,20',
      diferenca: '-R$ 26,80',
      data: '09/05/2026',
    },
    {
      status: 'Pendente',
      pedido: '#AM-88311',
      nf: 'NF-10031',
      plataforma: 'Amazon',
      esperado: 'R$ 2.390,00',
      recebido: '-',
      diferenca: '-',
      data: '10/05/2026',
    },
    {
      status: 'Conciliado',
      pedido: '#MG-66192',
      nf: 'NF-10032',
      plataforma: 'Magalu',
      esperado: 'R$ 530,00',
      recebido: 'R$ 530,00',
      diferenca: 'R$ 0,00',
      data: '09/05/2026',
    },
  ]

  const statusStyle = {
    Conciliado:
      'bg-emerald-500/15 text-emerald-400 border border-emerald-500/20',
    Divergente:
      'bg-red-500/15 text-red-400 border border-red-500/20',
    Pendente:
      'bg-yellow-500/15 text-yellow-400 border border-yellow-500/20',
  }

  return (
    <div className="min-h-screen bg-zinc-950 text-white p-6">
      <div className="max-w-7xl mx-auto space-y-6">
        <div className="flex flex-col lg:flex-row lg:items-center lg:justify-between gap-4">
          <div>
            <p className="text-zinc-400 text-sm">Conciliação Financeira</p>
            <h1 className="text-3xl font-bold tracking-tight mt-1">
              Central de Conciliação
            </h1>
          </div>

          <div className="flex flex-wrap gap-3">
            <select className="bg-zinc-900 border border-zinc-800 rounded-xl px-4 py-3 text-sm outline-none focus:border-zinc-600">
              <option>Últimos 30 dias</option>
              <option>Últimos 7 dias</option>
              <option>Hoje</option>
            </select>

            <select className="bg-zinc-900 border border-zinc-800 rounded-xl px-4 py-3 text-sm outline-none focus:border-zinc-600">
              <option>Todas plataformas</option>
              <option>Mercado Livre</option>
              <option>Shopee</option>
              <option>Amazon</option>
              <option>Magalu</option>
            </select>

            <button className="bg-white text-black font-medium px-5 py-3 rounded-xl hover:opacity-90 transition">
              Processar Conciliação
            </button>
          </div>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-2 xl:grid-cols-2 gap-4">
          {stats.map((item) => (
            <div
              key={item.title}
              className="bg-zinc-900 border border-zinc-800 rounded-3xl p-5 shadow-xl"
            >
              <div className="flex items-start justify-between">
                <div>
                  <p className="text-sm text-zinc-400">{item.title}</p>
                  <h2 className="text-2xl font-bold mt-3">{item.value}</h2>
                </div>

                <div className="bg-zinc-800 text-zinc-300 text-xs px-3 py-1 rounded-full">
                  {item.change}
                </div>
              </div>
            </div>
          ))}
        </div>

        <div className="bg-zinc-900 border border-zinc-800 rounded-3xl overflow-hidden shadow-2xl">
          <div className="flex flex-col lg:flex-row lg:items-center lg:justify-between gap-4 p-5 border-b border-zinc-800">
            <div>
              <h2 className="text-lg font-semibold">Movimentações conciliadas</h2>
              <p className="text-zinc-400 text-sm mt-1">
                Controle completo dos recebimentos, divergências e repasses.
              </p>
            </div>

            <div className="flex flex-wrap gap-3">
              <input
                placeholder="Buscar pedido, NF ou valor"
                className="bg-zinc-950 border border-zinc-800 rounded-xl px-4 py-3 text-sm min-w-[260px] outline-none focus:border-zinc-600"
              />

              <select className="bg-zinc-950 border border-zinc-800 rounded-xl px-4 py-3 text-sm outline-none focus:border-zinc-600">
                <option>Todos status</option>
                <option>Conciliado</option>
                <option>Divergente</option>
                <option>Pendente</option>
              </select>
            </div>
          </div>

          <div className="overflow-x-auto">
            <table className="w-full min-w-[1100px]">
              <thead className="bg-zinc-950/80 text-zinc-400 text-sm">
                <tr>
                  <th className="text-left font-medium px-6 py-4">Status</th>
                  <th className="text-left font-medium px-6 py-4">Pedido</th>
                  <th className="text-left font-medium px-6 py-4">NF</th>
                  <th className="text-left font-medium px-6 py-4">Plataforma</th>
                  <th className="text-left font-medium px-6 py-4">Valor Esperado</th>
                  <th className="text-left font-medium px-6 py-4">Valor Recebido</th>
                  <th className="text-left font-medium px-6 py-4">Diferença</th>
                  <th className="text-left font-medium px-6 py-4">Data</th>
                  <th className="text-left font-medium px-6 py-4">Ações</th>
                </tr>
              </thead>

              <tbody>
                {rows.map((row) => (
                  <tr
                    key={row.pedido}
                    className="border-t border-zinc-800 hover:bg-zinc-800/30 transition"
                  >
                    <td className="px-6 py-5">
                      <span
                        className={`px-3 py-1 rounded-full text-xs font-medium ${statusStyle[row.status]}`}
                      >
                        {row.status}
                      </span>
                    </td>

                    <td className="px-6 py-5 font-medium">{row.pedido}</td>
                    <td className="px-6 py-5 text-zinc-300">{row.nf}</td>
                    <td className="px-6 py-5 text-zinc-300">
                      {row.plataforma}
                    </td>
                    <td className="px-6 py-5">{row.esperado}</td>
                    <td className="px-6 py-5">{row.recebido}</td>
                    <td className="px-6 py-5 font-medium">
                      {row.diferenca}
                    </td>
                    <td className="px-6 py-5 text-zinc-400">{row.data}</td>

                    <td className="px-6 py-5">
                      <div className="flex gap-2">
                        <button className="bg-zinc-800 hover:bg-zinc-700 transition px-3 py-2 rounded-lg text-sm">
                          Detalhes
                        </button>

                        <button className="bg-zinc-800 hover:bg-zinc-700 transition px-3 py-2 rounded-lg text-sm">
                          Reprocessar
                        </button>
                      </div>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </div>

        <div className="grid grid-cols-1 xl:grid-cols-3 gap-4">
          <div className="xl:col-span-2 bg-zinc-900 border border-zinc-800 rounded-3xl p-6">
            <div className="flex items-center justify-between mb-6">
              <div>
                <h3 className="text-lg font-semibold">
                  Divergências recentes
                </h3>
                <p className="text-zinc-400 text-sm mt-1">
                  Valores com diferença entre OMIE e marketplace.
                </p>
              </div>

              <button className="text-sm bg-red-500/15 text-red-400 border border-red-500/20 px-4 py-2 rounded-xl">
                17 pendentes
              </button>
            </div>

            <div className="space-y-4">
              {[1, 2, 3].map((item) => (
                <div
                  key={item}
                  className="bg-zinc-950 border border-zinc-800 rounded-2xl p-4 flex flex-col lg:flex-row lg:items-center lg:justify-between gap-4"
                >
                  <div>
                    <p className="font-medium">Pedido #SP-11382</p>
                    <p className="text-sm text-zinc-400 mt-1">
                      Diferença detectada de R$ 26,80 no repasse.
                    </p>
                  </div>

                  <div className="flex gap-2">
                    <button className="bg-zinc-800 hover:bg-zinc-700 px-4 py-2 rounded-xl text-sm transition">
                      Ver detalhes
                    </button>

                    <button className="bg-white text-black px-4 py-2 rounded-xl text-sm font-medium hover:opacity-90 transition">
                      Abrir contestação
                    </button>
                  </div>
                </div>
              ))}
            </div>
          </div>

          <div className="bg-zinc-900 border border-zinc-800 rounded-3xl p-6">
            <div>
              <h3 className="text-lg font-semibold">Resumo operacional</h3>
              <p className="text-zinc-400 text-sm mt-1">
                Situação financeira das plataformas.
              </p>
            </div>

            <div className="mt-6 space-y-5">
              <div className="flex items-center justify-between">
                <span className="text-zinc-400">Marketplace</span>
                <span className="font-medium">4 conectados</span>
              </div>

              <div className="flex items-center justify-between">
                <span className="text-zinc-400">Processamentos hoje</span>
                <span className="font-medium">28</span>
              </div>

              <div className="flex items-center justify-between">
                <span className="text-zinc-400">Pendências abertas</span>
                <span className="font-medium text-yellow-400">17</span>
              </div>

              <div className="flex items-center justify-between">
                <span className="text-zinc-400">Última sincronização</span>
                <span className="font-medium">há 2 min</span>
              </div>
            </div>

            <div className="mt-8 bg-zinc-950 border border-zinc-800 rounded-2xl p-4">
              <p className="text-sm text-zinc-400">Fluxo de caixa previsto</p>

              <h2 className="text-3xl font-bold mt-3">
                R$ 89.332,10
              </h2>

              <p className="text-emerald-400 text-sm mt-2">
                +14.8% comparado ao período anterior
              </p>
            </div>
          </div>
        </div>
      </div>
    </div>
  )
}
