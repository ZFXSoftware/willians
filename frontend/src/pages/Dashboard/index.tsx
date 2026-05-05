import { useEffect, useState } from "react"
import { api } from "../../api/client"
import "./dashboard.css"
import { dashboardMock } from "../../mocks/dashboard"

export default function Dashboard() {
  const [data, setData] = useState<any>(null)

  useEffect(() => {
    // simula delay de API
    setTimeout(() => {
      setData(dashboardMock)
    }, 500)
  }, [])

  if (!data) return <div className="loading">Carregando...</div>

  return (
    <div className="dashboard-container">
      <h1 className="dashboard-title">Dashboard</h1>

      {/* KPIs */}
      <div className="kpi-grid">
        <div className="kpi-card">
          <span>Saldo Virtual</span>
          <h2>R$ {data.balance}</h2>
        </div>

        <div className="kpi-card">
          <span>A Receber</span>
          <h2>R$ {data.to_receive}</h2>
        </div>

        <div className="kpi-card">
          <span>Conciliado</span>
          <h2>R$ {data.matched}</h2>
        </div>

        <div className="kpi-card danger">
          <span>Divergências</span>
          <h2>R$ {data.divergences}</h2>
        </div>
      </div>

      {/* Tabela */}
      <div className="table-container">
        <h2>Últimas Transações</h2>

        <table>
          <thead>
            <tr>
              <th>Data</th>
              <th>Descrição</th>
              <th>Valor</th>
              <th>Status</th>
            </tr>
          </thead>

          <tbody>
            {data.transactions.map((t: any, i: number) => (
              <tr key={i}>
                <td>{t.date}</td>
                <td>{t.description}</td>
                <td>R$ {t.amount}</td>
                <td>
                  <span className={`status ${t.status}`}>
                    {t.status}
                  </span>
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  )
}