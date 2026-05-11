import { conciliacaoQueue } from "../queues/conciliacao.queue"

export function startScheduler() {
  setInterval(async () => {
    console.log("Enfileirando conciliação...")
    
    await conciliacaoQueue.add("processar", {}, {
      attempts: 5,
      backoff: {
        type: "exponential",
        delay: 2000
      }
    })

  }, 1000 * 60 * 5) // 5 minutos
}