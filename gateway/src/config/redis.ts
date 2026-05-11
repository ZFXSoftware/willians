import IORedis from "ioredis"

export const redis = new IORedis({
  host: "redis", // se estiver no docker
  port: 6379,
  maxRetriesPerRequest: null
})