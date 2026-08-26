import { railsClient } from "../services/railsClient"

export interface ImportarNotasJobData {
  tenant_id?: number | string
  start_date?: string
  end_date?: string
}

// Traz as notas fiscais do Tiny para o banco do Willians.
//
// Vai pela fila porque são milhares de notas em páginas de 100: a leitura
// inteira passa de qualquer tempo de requisição de navegador, e o usuário não
// pode ficar com a tela travada esperando.
//
// NÃO toca no OMIE — levar as notas para lá é outro passo, com trava própria.
export async function importarNotas(data: ImportarNotasJobData = {}) {
  const response = await railsClient.post("/fiscal/notas/importar", data)

  console.log("[notas] importação concluída:", JSON.stringify(response.data))

  return response.data
}
