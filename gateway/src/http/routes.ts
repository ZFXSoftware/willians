import { Router } from "express"
import { conciliacaoQueue } from "../queues/conciliacao.queue"
import { railsUserClient } from "../services/railsClient"
import { ConciliacaoJobData } from "../jobs/processarConciliacao.job"

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

// Trigger manual.
//
// A identidade é verificada aqui, de forma síncrona, contra o /auth/me do Rails
// — e só o tenant_id vai para a fila. O token do usuário nunca é persistido no
// Redis, que guarda os jobs em disco (appendonly).
router.post("/conciliacoes/processar", async (req, res) => {
  const authorization = req.headers.authorization

  if (!authorization) {
    return res.status(401).json({ status: "error", error: "Não autenticado" })
  }

  let tenants: TenantMembership[]

  try {
    const me = await railsUserClient.get("/auth/me", {
      headers: { Authorization: authorization },
    })

    tenants = me.data?.tenants ?? []
  } catch (err: any) {
    const status = err?.response?.status === 401 ? 401 : 502

    return res.status(status).json({
      status: "error",
      error: status === 401 ? "Sessão inválida ou expirada" : "Backend indisponível",
    })
  }

  const { tenant_id, platform_account_id, start_date, end_date, sincronizar, forcar } =
    (req.body ?? {}) as ConciliacaoJobData

  const tenantId = tenant_id ?? (tenants.length === 1 ? tenants[0].id : undefined)

  if (!tenantId) {
    return res.status(400).json({
      status: "error",
      error: "Informe tenant_id — seu usuário pertence a mais de uma organização",
    })
  }

  const membership = tenants.find((t) => String(t.id) === String(tenantId))

  if (!membership) {
    return res.status(403).json({ status: "error", error: "Sem acesso a esta organização" })
  }

  if (!WRITE_ROLES.includes(membership.role)) {
    return res.status(403).json({
      status: "error",
      error: "Seu perfil não permite disparar a conciliação",
    })
  }

  try {
    const job = await conciliacaoQueue.add(
      "processar",
      { tenant_id: tenantId, platform_account_id, start_date, end_date, sincronizar, forcar },
      {
        attempts: 5,
        backoff: { type: "exponential", delay: 2000 },
        removeOnComplete: 100,
        removeOnFail: 500,
      },
    )

    return res.status(202).json({ status: "enfileirado", job_id: job.id })
  } catch (err) {
    console.error("[routes] falha ao enfileirar:", err)

    return res.status(503).json({ status: "error", error: "Fila indisponível" })
  }
})
