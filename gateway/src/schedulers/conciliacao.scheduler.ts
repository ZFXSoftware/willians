import { conciliacaoQueue } from "../queues/conciliacao.queue"

const SCHEDULER_ID = "conciliacao-periodica"

const EVERY_MS = Number(process.env.CONCILIACAO_INTERVAL_MS || 5 * 60 * 1000)

// Job repetível do BullMQ em vez de setInterval: o agendamento vive no Redis,
// sobrevive a restart do container e não duplica se mais de um scheduler subir.
export async function startScheduler() {
  await conciliacaoQueue.upsertJobScheduler(
    SCHEDULER_ID,
    { every: EVERY_MS },
    {
      name: "processar",
      data: {},
      opts: {
        attempts: 5,
        backoff: {
          type: "exponential",
          delay: 2000,
        },
        removeOnComplete: 100,
        removeOnFail: 500,
      },
    },
  )

  console.log(`Scheduler de conciliação ativo (a cada ${EVERY_MS / 1000}s)`)
}
