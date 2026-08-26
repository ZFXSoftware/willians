import { Worker } from "bullmq"
import { redis } from "../config/redis"
import {
  processarConciliacao,
  ConciliacaoJobData,
} from "../jobs/processarConciliacao.job"
import { importarNotas, ImportarNotasJobData } from "../jobs/importarNotas.job"

// A importação de notas usa a MESMA fila em vez de uma nova.
//
// Não por economia de código: as duas falam com o mesmo Rails e disputam o
// mesmo banco, e a concorrência 1 abaixo é justamente o que impede duas
// escritas pesadas ao mesmo tempo. Uma fila separada com worker próprio
// desfaria essa garantia sem ninguém perceber.
const IMPORTAR_NOTAS = "importar_notas"

// Concorrência 1: a conciliação é global por conta e duas execuções simultâneas
// na mesma janela disputariam os mesmos repasses.
const CONCURRENCY = 1

export function startWorker() {
  const worker = new Worker<ConciliacaoJobData | ImportarNotasJobData>(
    "conciliacao",
    async (job) =>
      job.name === IMPORTAR_NOTAS
        ? importarNotas(job.data as ImportarNotasJobData)
        : processarConciliacao(job.data as ConciliacaoJobData),
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
