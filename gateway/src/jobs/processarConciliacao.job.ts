import { railsClient } from "../services/railsClient"

export interface ConciliacaoJobData {
  tenant_id?: number | string
  platform_account_id?: number | string
  start_date?: string
  end_date?: string
}

export async function processarConciliacao(data: ConciliacaoJobData = {}) {
  const response = await railsClient.post("/conciliacoes/processar", data)

  console.log("[conciliacao] concluída:", JSON.stringify(response.data))

  return response.data
}
