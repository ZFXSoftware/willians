import { BrowserRouter, Routes, Route } from "react-router-dom"

import Login from "../pages/Login"
import Register from "../pages/Register"

import Dashboard from "../pages/Dashboard"
import ReconciliationDashboard from "../pages/Reconciliation/reconciliation-dashboard"
import Divergences from "../pages/Divergences"
import Integrations from "../pages/Integrations"

import PrivateRoute from "./privateRoute"
import MainLayout from "../layouts/MainLayout"

export default function AppRoutes() {
  return (
    <BrowserRouter>
      <Routes>
        {/* públicas */}
        <Route path="/login" element={<Login />} />
        <Route path="/register" element={<Register />} />

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

          <Route path="/divergencias" element={<Divergences />} />
          <Route path="/integracoes" element={<Integrations />} />
        </Route>
      </Routes>
    </BrowserRouter>
  )
}