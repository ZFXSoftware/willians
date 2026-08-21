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
| Amazon        | **conexão e leitura financeira completas**                         |
| Mercado Livre | conexão pronta; faturamento lido; repasses pendentes               |
| Shopee        | conexão pronta; **leitura financeira pendente**                    |
| Magalu        | não implementada                                                   |

As três conexões usam a mesma fundação: token cifrado em `marketplace_credentials`,
`state` de uso único e renovação sob lock. O que muda é a autenticação de cada uma:

| | Autenticação | access token | refresh token |
| --- | --- | --- | --- |
| Mercado Livre | OAuth 2.0, Bearer | 6 horas | uso único, 6 meses |
| Shopee | HMAC-SHA256 por chamada | 4 horas | 30 dias |
| Amazon | LWA (sem SigV4 desde 2023) | 1 hora | até o vendedor revogar |

### Onde ficam as chaves de API

Há dois níveis, e eles não se confundem:

| | O que é | Onde vive |
| --- | --- | --- |
| Credencial de **aplicativo** | O app que você registrou no OMIE, no Mercado Livre, na Shopee, na Amazon e no Tiny | `integration_settings`, cifrado, **por empresa** — preenchido na tela de Configurações |
| Credencial de **conta** | O token que cada lojista concede ao autorizar | `marketplace_credentials`, cifrado — resultado do OAuth |

A tela de Configurações (`/configuracoes`) é a forma normal de preencher o
primeiro nível: ela mostra o que falta, de onde veio cada valor e a URL de
retorno que precisa ser cadastrada no portal da plataforma. Segredo gravado
nunca volta pela API — a tela exibe só os últimos caracteres.

As variáveis do `.env` continuam valendo como **padrão do servidor**: se
ninguém preencheu na tela, é o que o sistema usa (aparece como "Vem do
servidor"). Preencher na tela sobrescreve; apagar na tela devolve a vez ao
`.env`. Isso mantém o deploy atual funcionando e abre caminho para o SaaS, onde
cada empresa traz o próprio aplicativo.

`OMIE_ALLOW_WRITES` **não** entra na tela de propósito: liberar gravação na
contabilidade do cliente é decisão de quem opera o servidor, não de quem usa a
interface.

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

#### O que já é lido do Mercado Livre

A API de Relatórios de Faturamento (`/billing/integration`), nos grupos `ML` e
`MP`. Dela vêm os **encargos** (comissão de venda, Mercado Envios, Product Ads)
como lançamentos de `fee`, e as **bonificações** — devoluções desses encargos —
como `adjustment`.

Só períodos **fechados** são ingeridos: enquanto o período está `OPEN` os valores
ainda mudam, e o ledger é imutável, então ingerir cedo congelaria um valor
parcial para sempre.

#### O que ainda falta

- **Os repasses** (o dinheiro efetivamente liberado ao vendedor). A API de
  faturamento cobre o que o ML *cobra*, não o que ele *paga*. Sem isso, os
  `PayoutBatch` continuam vindo de outra origem.
- **O detalhe por venda.** O faturamento vem agregado por período mensal, sem
  vínculo com o pedido — por isso esses lançamentos não são alocados a nenhum
  recebível. Existe um endpoint `/details` por período que traria o detalhe, mas
  o schema da resposta ainda não foi confirmado.

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

## Colocando em produção

A VPS tem outros sistemas. Todo o desenho do deploy parte disso:

- a stack sobe com nome de projeto próprio (`willians-prod`) e volumes próprios,
  então não encosta em containers nem dados de mais ninguém;
- publica **uma** porta, e só em `127.0.0.1`. Quem fala com a internet é o nginx
  do host;
- a porta é verificada antes de usar; ocupada, o script para em vez de brigar;
- nenhum arquivo do nginx é sobrescrito sem cópia de segurança;
- o sistema antigo é **parado, nunca apagado** — voltar é um comando.

### Por que não é só `git pull` e subir de novo

| | |
| --- | --- |
| **Esquema mudou** | Autenticação própria substituiu o Supabase, e entraram `integration_settings`, `devolucoes` e colunas novas. Sem migrar, o app não sobe |
| **Variáveis novas obrigatórias** | `SECRET_KEY_BASE`, `AR_ENCRYPTION_*` (sem elas os tokens de marketplace não decifram), `POSTGRES_PASSWORD`, `SERVICE_API_TOKEN` |
| **O compose de desenvolvimento não serve** | Ele roda vite dev server e `ts-node-dev`, monta o código do host e publica seis portas em `0.0.0.0` |
| **Login mudou** | Usuários antigos eram do Supabase e não entram. É preciso criar o primeiro administrador |

### Passo a passo

```bash
git clone git@github.com:ZFXSoftware/willians.git
cd willians

./deploy/deploy.sh inspecionar        # o que já existe (não muda nada)
./deploy/deploy.sh preparar           # cria .env.production e gera os segredos
nano .env.production                  # domínio e chaves do OMIE
./deploy/deploy.sh subir              # constrói e sobe, ainda sem publicar
./deploy/deploy.sh migrar             # backup + migrações + primeiro usuário
./deploy/deploy.sh status             # conferência local
```

Até aqui **nada mudou para quem usa o sistema antigo**: a stack nova responde
só em `127.0.0.1`. Confira por um túnel SSH antes de publicar:

```bash
ssh -L 8090:127.0.0.1:8090 usuario@vps     # e abra http://localhost:8090
```

Convencido, publique e vire:

```bash
./deploy/deploy.sh publicar app.exemplo.com.br   # escreve o site, DESATIVADO
./deploy/deploy.sh trocar   app.exemplo.com.br   # desativa o antigo, ativa o novo
./deploy/deploy.sh parar-antigo willians         # para o antigo (não apaga)
```

`publicar` escreve o site mas **não o ativa**: dois sites com o mesmo
`server_name` fariam o nginx ignorar um deles em silêncio. Quem ativa é o
`trocar`, na mesma operação em que desativa o antigo — e ele descobre quais
desativar procurando pelo `server_name`, não por nome de arquivo, porque a
instalação anterior pode ter qualquer nome.

Se algo der errado:

```bash
./deploy/deploy.sh reverter            # restaura a configuração anterior do nginx
docker compose -p willians start       # religa o sistema antigo
```

### O que foi verificado

A stack de produção foi construída e subida por inteiro antes deste texto
existir: oito containers, migrações aplicadas, cadastro criado passando por
nginx -> Rails -> Postgres, `/gateway/health` respondendo, e o Solid Queue
subindo com `refresh_marketplace_credentials` no agendamento — o job que antes
não rodava por falta de supervisor.

Só uma porta aparece publicada, e em `127.0.0.1`:

```
willians-prod-web-1   ...   127.0.0.1:8090->80/tcp
```

### Depois de publicar

O OAuth dos marketplaces exige HTTPS e uma `redirect_uri` fixa. Cadastre no
portal de cada plataforma exatamente:

```
https://SEU-DOMINIO/api/integracoes/mercado-livre/callback
https://SEU-DOMINIO/api/integracoes/shopee/callback
https://SEU-DOMINIO/api/integracoes/amazon/callback
```

E deixe `OMIE_ALLOW_WRITES` **vazio** até rodar em simulação e conferir o que o
sistema faria. Com `true`, ele passa a gravar na contabilidade do cliente.

## Limitações conhecidas

### Distância entre o construído e o briefing

O briefing ancora a conciliação na **nota fiscal**: baixa dos recebimentos das
NFs, recebíveis futuros vinculados a NF e pedido, devoluções ligadas à NF de
origem. Hoje a conciliação é ancorada no repasse, e a tabela `invoices` não é
populada por ninguém.

Também não existem, e estão no escopo: valores não vinculados em categoria
transitória, transferências e pagamentos no modelo OMIE.Cash, contestação de
divergência na central da plataforma, e o espelho do saldo da conta virtual.

### Dívida planejada: credencial do Omie é global

`Omie::Client` lê `OMIE_APP_KEY`/`OMIE_APP_SECRET` do ambiente — um par para toda
a instância. **Isso está correto para o modelo atual**, de um cliente por
instância.

Se o sistema virar SaaS multi-cliente, isso passa a ser uma falha grave:
conciliar o Tenant B consultaria o Omie do Tenant A e todo resultado sairia
errado. A correção é mover a credencial para o banco, cifrada por tenant, e fazer
`Omie::Client` receber o tenant nos sete pontos de uso. A estrutura multi-tenant
do resto do sistema já está pronta para isso.

### Não há tela de configuração

Credenciais e códigos do Omie só podem ser configurados por variável de ambiente
ou editando `metadata` pelo console do Rails. A página de Integrações do frontend
é mock.

## Estado do frontend

As telas de Dashboard, Conciliação, Divergências e Integrações ainda usam dados
**fixos no código** — não consultam a API. Só o login, o cadastro e o logout
falam com o backend de verdade.
