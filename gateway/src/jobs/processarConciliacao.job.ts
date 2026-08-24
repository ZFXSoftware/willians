import { railsClient } from "../services/railsClient"

export interface ConciliacaoJobData {
  tenant_id?: number | string
  platform_account_id?: number | string
  start_date?: string
  end_date?: string
  // Buscar do marketplace antes de conciliar. Padrão do Rails é true — sem
  // isso a conciliação compara o OMIE com um razão que ninguém alimentou.
  sincronizar?: boolean
  // Ignora a trava de intervalo mínimo entre ingestões. É o que o botão
  // "Sincronizar agora" manda: o usuário pediu, então vai agora.
  forcar?: boolean
}

export async function processarConciliacao(data: ConciliacaoJobData = {}) {
  const response = await railsClient.post("/conciliacoes/processar", data)

  console.log("[conciliacao] concluída:", JSON.stringify(response.data))

  return response.data
}
