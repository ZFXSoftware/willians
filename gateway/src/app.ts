// src/app.ts
import { startHttpServer } from "./http/server"
import { startWorker } from "./workers/conciliacao.worker"
import { startScheduler } from "./schedulers/conciliacao.scheduler"

const MODE = process.env.MODE || "api"

// Os módulos são importados sem efeito colateral: antes, o import do worker no
// topo do arquivo subia um consumidor da fila também nos modos api e scheduler.
async function main() {
  switch (MODE) {
    case "api":
      startHttpServer()
      break

    case "worker":
      startWorker()
      break

    case "scheduler":
      await startScheduler()
      break

    default:
      throw new Error(`MODE desconhecido: ${MODE}`)
  }
}

main().catch((err) => {
  console.error("Falha ao iniciar o gateway:", err)
  process.exit(1)
})
