import axios from "axios"

export const railsClient = axios.create({
  baseURL: "http://backend:3000",
  timeout: 10000
})