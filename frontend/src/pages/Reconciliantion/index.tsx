import { useEffect, useState } from "react"
import { api } from "../../api/client"

export default function Reconciliation() {
  const [transactions, setTransactions] = useState([])

  useEffect(() => {
    api.get("/transactions").then((res) => {
      setTransactions(res.data)
    })
  }, [])

  return (
    <div className="p-4">
      <h1 className="text-xl font-bold mb-4">Conciliação</h1>

      <table className="w-full border">
        <thead>
          <tr>
            <th>Data</th>
            <th>Descrição</th>
            <th>Valor</th>
            <th>Status</th>
          </tr>
        </thead>
        <tbody>
          {transactions.map((t: any, i) => (
            <tr key={i}>
              <td>{t.date}</td>
              <td>{t.description}</td>
              <td>{t.amount}</td>
              <td>{t.matched ? "✔️" : "❌"}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}