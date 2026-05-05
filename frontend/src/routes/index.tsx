import { BrowserRouter, Routes, Route } from "react-router-dom"
import Login from "../pages/Login"
import Home from "../pages/Home"
import Dashboard from "../pages/Dashboard"
import PrivateRoute from "./privateRoute"

export default function AppRoutes() {
  return (
    <BrowserRouter>
      <Routes>
        <Route path="/login" element={<Login />} />

        <Route
          path="/"
          element={
            <PrivateRoute>
              <Home />
              <Dashboard />
            </PrivateRoute>
          }
        />
      </Routes>
    </BrowserRouter>
  )
}