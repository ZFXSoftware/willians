import { Worker } from "bullmq"
import { redis } from "../config/redis"
import {
  processarConciliacao,
  ConciliacaoJobData,
} from "../jobs/processarConciliacao.job"

// Concorrência 1: a conciliação é global por conta e duas execuções simultâneas
// na mesma janela disputariam os mesmos repasses.
const CONCURRENCY = 1

export function startWorker() {
  const worker = new Worker<ConciliacaoJobData>(
    "conciliacao",
    async (job) => processarConciliacao(job.data),
    {
      connection: redis,
      concurrency: CONCURRENCY,
    },
  )

  worker.on("failed", (job, err) => {
    console.error(`[worker] job ${job?.id} falhou:`, err.message)
  })

  worker.on("error", (err) => {
    console.error("[worker] erro:", err.message)
  })

  console.log("Worker de conciliação rodando")

  return worker
}
