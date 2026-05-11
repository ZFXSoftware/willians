import express from "express"
import { router } from "./routes"

export function startHttpServer() {
  const app = express()

  app.use(express.json())
  app.use(router)

  app.listen(3001, () => {
    console.log("Gateway rodando na porta 3001")
  })
}