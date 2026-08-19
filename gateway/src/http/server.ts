import express from "express"
import { router } from "./routes"

const PORT = Number(process.env.PORT || 3001)

export function startHttpServer() {
  const app = express()

  app.use(express.json())
  app.use(router)

  return app.listen(PORT, () => {
    console.log(`Gateway rodando na porta ${PORT}`)
  })
}
