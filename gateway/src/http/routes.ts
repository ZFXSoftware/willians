import { Request, Response, Router } from "express"
import { conciliacaoQueue } from "../queues/conciliacao.queue"
import { railsUserClient } from "../services/railsClient"
import { ConciliacaoJobData } from "../jobs/processarConciliacao.job"
import { ImportarNotasJobData } from "../jobs/importarNotas.job"

export const router = Router()

const WRITE_ROLES = ["owner", "admin"]

interface TenantMembership {
  id: number
  name: string
  role: string
}

router.get("/health", (_req, res) => {
  res.json({ status: "ok" })
})

// Quem é, e pode?
//
// A identidade é verificada aqui, de forma síncrona, contra o /auth/me do Rails
// — e só o tenant_id vai para a fila. O token do usuário nunca é persistido no
// Redis, que guarda os jobs em disco (appendonly).
//
// Devolve o tenant autorizado, ou null quando JÁ respondeu com o erro. Ficou
// numa função porque a segunda rota precisa exatamente da mesma verificação, e
// copiar uma checagem de permissão é como ela acaba divergindo.
async function autorizar(
  req: Request,
  res: Response,
  acao: string,
): Promise<number | string | null> {
  const authorization = req.headers.authorization

  if (!authorization) {
    res.status(401).json({ status: "error", error: "Não autenticado" })
    return null
  }

  let tenants: TenantMembership[]

  try {
    const me = await railsUserClient.get("/auth/me", {
      headers: { Authorization: authorization },
    })

    tenants = me.data?.tenants ?? []
  } catch (err: any) {
    const status = err?.response?.status === 401 ? 401 : 502

    res.status(status).json({
      status: "error",
      error: status === 401 ? "Sessão inválida ou expirada" : "Backend indisponível",
    })

    return null
  }

  const pedido = (req.body ?? {}).tenant_id

  const tenantId = pedido ?? (tenants.length === 1 ? tenants[0].id : undefined)

  if (!tenantId) {
    res.status(400).json({
      status: "error",
      error: "Informe tenant_id — seu usuário pertence a mais de uma organização",
    })

    return null
  }

  const membership = tenants.find((t) => String(t.id) === String(tenantId))

  if (!membership) {
    res.status(403).json({ status: "error", error: "Sem acesso a esta organização" })
    return null
  }

  if (!WRITE_ROLES.includes(membership.role)) {
    res.status(403).json({
      status: "error",
      error: `Seu perfil não permite ${acao}`,
    })

    return null
  }

  return tenantId
}

async function enfileirar(res: Response, nome: string, dados: object) {
  try {
    const job = await conciliacaoQueue.add(nome, dados, {
      attempts: 5,
      backoff: { type: "exponential", delay: 2000 },
      removeOnComplete: 100,
      removeOnFail: 500,
    })

    return res.status(202).json({ status: "enfileirado", job_id: job.id })
  } catch (err) {
    console.error("[routes] falha ao enfileirar:", err)

    return res.status(503).json({ status: "error", error: "Fila indisponível" })
  }
}

router.post("/conciliacoes/processar", async (req, res) => {
  const tenantId = await autorizar(req, res, "disparar a conciliação")

  if (!tenantId) return

  const { platform_account_id, start_date, end_date, sincronizar, forcar } =
    (req.body ?? {}) as ConciliacaoJobData

  return enfileirar(res, "processar", {
    tenant_id: tenantId,
    platform_account_id,
    start_date,
    end_date,
    sincronizar,
    forcar,
  })
})

// Importa as notas fiscais do Tiny para o banco do Willians.
//
// Pela fila porque são milhares de notas em páginas de 100: a leitura inteira
// passa de qualquer tempo de requisição de navegador. NÃO toca no OMIE.
router.post("/fiscal/notas/importar", async (req, res) => {
  const tenantId = await autorizar(req, res, "importar notas fiscais")

  if (!tenantId) return

  const { start_date, end_date } = (req.body ?? {}) as ImportarNotasJobData

  return enfileirar(res, "importar_notas", {
    tenant_id: tenantId,
    start_date,
    end_date,
  })
})
