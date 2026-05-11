import { BrowserRouter, Routes, Route } from "react-router-dom"

import Login from "../pages/Login"

import Dashboard from "../pages/Dashboard"
import ReconciliationDashboard from "../pages/Reconciliation/reconciliation-dashboard"

import PrivateRoute from "./privateRoute"
import MainLayout from "../layouts/MainLayout"

export default function AppRoutes() {
  return (
    <BrowserRouter>
      <Routes>
        {/* pública */}
        <Route path="/login" element={<Login />} />

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
        </Route>
      </Routes>
    </BrowserRouter>
  )
}