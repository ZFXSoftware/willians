import { Worker } from "bullmq"
import { redis } from "../config/redis"
import { processarConciliacao } from "../jobs/processarConciliacao.job"

new Worker(
  "conciliacao",
  async () => {
    await processarConciliacao()
  },
  {
    connection: redis,
    concurrency: 2
  }
)