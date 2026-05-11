// src/app.ts
import { startHttpServer } from "./http/server"
import "./workers/conciliacao.worker"
import { startScheduler } from "./schedulers/conciliacao.scheduler"

const MODE = process.env.MODE

if (MODE === "api") {
  startHttpServer()
}

if (MODE === "worker") {
  console.log("Worker rodando")
  require("./workers/conciliacao.worker")
}

if (MODE === "scheduler") {
  startScheduler()
}