import { railsClient } from "../services/railsClient"

export async function processarConciliacao() {
  const response = await railsClient.post("/conciliacoes/processar")
  console.log("Conciliação executada:", response.data)
}