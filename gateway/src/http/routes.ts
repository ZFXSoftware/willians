import { Router } from "express"
import { conciliacaoQueue } from "../queues/conciliacao.queue"

export const router = Router()

// trigger manual
router.post("/conciliacoes/processar", async (req, res) => {
  await conciliacaoQueue.add("processar", {})

  res.json({ status: "enfileirado" })
})