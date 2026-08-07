Plataforma de conciliação financeira entre marketplaces e o ERP Omie.

O marketplace vende, desconta taxas, agenda repasses e paga em lote — o valor que
cai na conta raramente bate com o título a receber no Omie. O sistema ingere os
eventos financeiros, projeta os recebíveis, casa os repasses e registra as
divergências.

---

## Status

![Docker](https://img.shields.io/badge/docker-compose-blue?logo=docker)
![Rails](https://img.shields.io/badge/rails-8.1-red?logo=rubyonrails)
![Node](https://img.shields.io/badge/node-gateway-green?logo=node.js)
![PostgreSQL](https://img.shields.io/badge/postgresql-15-blue?logo=postgresql)
![Status](https://img.shields.io/badge/status-dev-yellow)

---

## Arquitetura

```
frontend (React/Vite) → gateway (Express + BullMQ) → backend (Rails API) → PostgreSQL
                                  ↕ Redis
                        worker + scheduler (mesma imagem, variável MODE)
```

---

## Como rodar

```bash
cp .env.example .env     # preencha ao menos USER_ID/GROUP_ID e SERVICE_API_TOKEN
docker compose up
```

Gere o token máquina-a-máquina com `openssl rand -hex 32`. Sem ele, worker e
scheduler tomam 401 do backend.

Na primeira vez (e sempre que o schema mudar):

```bash
docker compose exec backend bin/rails db:migrate
docker compose exec backend bin/rails db:seed
```

O `db:seed` só cria usuário se `SEED_ADMIN_PASSWORD` estiver no `.env`.

### Serviços

| Serviço  | URL                     | Observação                          |
| -------- | ----------------------- | ----------------------------------- |
| Proxy    | http://localhost:8080   | origem única (use com o túnel)      |
| Frontend | http://localhost:5173   | leva ~1 min para o Vite subir       |
| Gateway  | http://localhost:3051   | `/health` e disparo da conciliação  |
| Backend  | http://localhost:3053   | API Rails                           |
| Redis    | localhost:6479          |                                     |
| Postgres | interno                 | sem porta publicada                 |

> A porta 3050 também está mapeada para o frontend, mas o Vite escuta na 5173 —
> use a 5173.

### Expondo por HTTPS (necessário para o OAuth dos marketplaces)

O serviço `proxy` junta frontend, `/api` e `/gateway` numa **origem única** na
porta 8080. Isso existe porque um túnel publica uma porta só, e o OAuth do
Mercado Livre exige uma `redirect_uri` **HTTPS fixa** apontando para o backend.

```bash
ngrok http 8080 --domain=SEU-DOMINIO.ngrok-free.dev
```

O plano free do ngrok dá um domínio estático permanente — use-o, porque a
`redirect_uri` registrada no Mercado Livre precisa bater exatamente e não pode
mudar a cada reinício do túnel. (O free também mostra uma página de aviso que
exige um clique antes de chegar no app; os planos pagos removem.)

No `.env`:

```
PUBLIC_HOST=SEU-DOMINIO.ngrok-free.dev
APP_PUBLIC_URL=https://SEU-DOMINIO.ngrok-free.dev
VITE_API_URL=/api
VITE_GATEWAY_URL=/gateway
```

`PUBLIC_HOST` libera o domínio no Rails (`config.hosts`) e no Vite
(`allowedHosts`) — sem isso os dois respondem "blocked host" antes de chegar na
aplicação, inclusive no callback do OAuth.

Com isso a URL de callback fica:

```
https://SEU-DOMINIO.ngrok-free.dev/api/integracoes/mercado-livre/callback
```

Rodando sem túnel, deixe essas variáveis vazias e use `localhost:5173` direto.

### Depois de mexer em dependências

`node_modules` e as gems vivem em volumes. Se você alterar `package.json` ou
`Gemfile`, recrie os volumes, senão os antigos mascaram a imagem nova:

```bash
docker compose up -d --build --force-recreate --renew-anon-volumes \
  frontend gateway worker scheduler
docker compose run --rm --user root backend bundle install
```

---

## Autenticação

Sessões próprias no Postgres (o Supabase foi removido). O banco guarda apenas o
hash do token; o logout revoga a sessão de verdade.

```bash
curl -X POST http://localhost:3053/auth/register \
  -H 'Content-Type: application/json' \
  -d '{"name":"Fulano","email":"fulano@empresa.com","password":"uma-senha-boa"}'
```

Quem se cadastra cria a própria organização e entra como `owner`. Endpoints:
`POST /auth/register`, `POST /auth/login`, `DELETE /auth/logout`, `GET /auth/me`.

Chamadas máquina-a-máquina (worker/scheduler) usam o header `X-Service-Token`.

---

## Integrações

| Integração    | Estado                                                             |
| ------------- | ------------------------------------------------------------------ |
| Omie          | leitura de títulos funcionando; escrita bloqueada por padrão       |
| Mercado Livre | OAuth e renovação de token prontos; **leitura financeira pendente** |
| Shopee        | não implementada                                                   |
| Amazon        | não implementada                                                   |
| Magalu        | não implementada                                                   |

### Conectando uma conta do Mercado Livre

Os tokens ficam em `marketplace_credentials`, **cifrados** — preencha as chaves
de encryption no `.env` antes (ver `.env.example`).

```
POST /api/integracoes/mercado-livre/autorizar   → devolve authorization_url
GET  /api/integracoes/mercado-livre/callback    → público, valida o state
DELETE /api/integracoes/mercado-livre/desconectar
```

O `access_token` dura 6 horas e é renovado sob demanda pelo `TokenProvider`
sempre que a conta é usada. O `refresh_token` é de **uso único**: cada renovação
devolve um novo, então ela acontece sob lock de linha para que duas execuções
concorrentes não desconectem a conta.

`Marketplace::RefreshCredentialsJob` é a rede de segurança para contas ociosas,
mas depende do supervisor do Solid Queue (`bin/jobs`), que ainda não está no
docker-compose.

Sem credencial, a ingestão usa um provider de **simulação** que gera lançamentos
fictícios — ligado por padrão só em desenvolvimento. Em produção é preciso
`MARKETPLACE_SIMULATION=true` explícito, justamente para não injetar dados falsos
no ledger sem querer.

Teste a conexão com o Omie (somente leitura, não grava nada):

```bash
docker compose exec backend bin/rails omie:check
docker compose exec backend bin/rails omie:settings
```

---

## Estado do frontend

As telas de Dashboard, Conciliação, Divergências e Integrações ainda usam dados
**fixos no código** — não consultam a API. Só o login, o cadastro e o logout
falam com o backend de verdade.
