import { BrowserRouter, Routes, Route } from "react-router-dom"

import Login from "../pages/Login"
import Register from "../pages/Register"

import Dashboard from "../pages/Dashboard"
import ReconciliationDashboard from "../pages/Reconciliation/reconciliation-dashboard"
import Divergences from "../pages/Divergences"
import Entries from "../pages/Entries"
import Processes from "../pages/Processes"
import Integrations from "../pages/Integrations"
import Settings from "../pages/Settings"
import Balances from "../pages/Balances"
import Returns from "../pages/Returns"
import Movements from "../pages/Movements"
import Team from "../pages/Team"
import Invite from "../pages/Invite"

import PrivateRoute from "./privateRoute"
import MainLayout from "../layouts/MainLayout"

export default function AppRoutes() {
  return (
    <BrowserRouter>
      <Routes>
        {/* públicas */}
        <Route path="/login" element={<Login />} />
        <Route path="/register" element={<Register />} />
        <Route path="/convite/:token" element={<Invite />} />

        {/* privadas */}
        <Route
          element={
            <PrivateRoute>
              <MainLayout />
            </PrivateRoute>
          }
        >
          <Route path="/" element={<Dashboard />} />

          <Route
            path="/conciliation"
            element={<ReconciliationDashboard />}
          />

          <Route path="/processos" element={<Processes />} />
          <Route path="/lancamentos" element={<Entries />} />
          <Route path="/divergencias" element={<Divergences />} />
          <Route path="/integracoes" element={<Integrations />} />
          <Route path="/saldos" element={<Balances />} />
          <Route path="/devolucoes" element={<Returns />} />
          <Route path="/movimentacoes" element={<Movements />} />
          <Route path="/equipe" element={<Team />} />
          <Route path="/configuracoes" element={<Settings />} />
        </Route>
      </Routes>
    </BrowserRouter>
  )
}