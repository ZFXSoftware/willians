import axios from "axios"
import { useAuth } from "../store/useAuth"

export const api = axios.create({
  baseURL: "http://localhost:3003",
})

api.interceptors.request.use((config) => {
  const token = useAuth.getState().token

  if (token) {
    config.headers.Authorization = `Bearer ${token}`
  }

  return config
})