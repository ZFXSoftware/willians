import { Queue } from "bullmq"
import { redis } from "../config/redis"

export const conciliacaoQueue = new Queue("conciliacao", {
  connection: redis
})