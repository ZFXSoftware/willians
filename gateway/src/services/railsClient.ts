import axios from "axios"

// Uma conciliação varre todos os repasses da janela e chama o OMIE — 10s
// estouravam antes do Rails responder e o job era marcado como falho mesmo
// quando o processamento seguia até o fim.
const TIMEOUT_MS = Number(process.env.RAILS_TIMEOUT_MS || 120_000)

const SERVICE_TOKEN = process.env.SERVICE_API_TOKEN || ""

if (!SERVICE_TOKEN) {
  console.warn(
    "[railsClient] SERVICE_API_TOKEN vazio — o Rails vai recusar as chamadas do worker/scheduler.",
  )
}

const baseURL = process.env.RAILS_URL || "http://backend:3000"

// Chamadas máquina-a-máquina (worker/scheduler): carregam a credencial de
// serviço, que vale por todos os tenants.
export const railsClient = axios.create({
  baseURL,
  timeout: TIMEOUT_MS,
  headers: SERVICE_TOKEN ? { "X-Service-Token": SERVICE_TOKEN } : {},
})

// Verificação de identidade do usuário final: deliberadamente SEM a credencial
// de serviço, para que ela não eleve o privilégio de quem estamos conferindo.
export const railsUserClient = axios.create({
  baseURL,
  timeout: TIMEOUT_MS,
})
