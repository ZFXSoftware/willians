Sistema full-stack com Rails (API), Node.js (Gateway/BFF) e PostgreSQL, orquestrado via Docker.

---

## Status

![Docker](https://img.shields.io/badge/docker-compose-blue?logo=docker)
![Rails](https://img.shields.io/badge/rails-api-red?logo=ruby)
![Node](https://img.shields.io/badge/node-gateway-green?logo=node.js)
![PostgreSQL](https://img.shields.io/badge/postgresql-db-blue?logo=postgresql)
![Status](https://img.shields.io/badge/status-dev-yellow)

---

## Arquitetura

Frontend → Gateway → Backend → Database

---

## Estrutura do projeto

* Frontend (futuro)
* Gateway (Node.js)
* Backend (Rails API)
* PostgreSQL

---

## Como rodar

```bash
docker compose up --build
```

---

## Serviços

* Frontend: [http://localhost:3000](http://localhost:3000)
* Gateway: [http://localhost:3001](http://localhost:3001)
* Backend: [http://localhost:3003](http://localhost:3003)
* Database: localhost:5432

---

## Exemplo de requisição

```bash
curl -X POST http://localhost:3001/api/users \
  -H "Content-Type: application/json" \
  -d '{"name":"Davi","email":"davi@email.com"}'
```

---

## Status de desenvolvimento

* [x] Docker
* [x] Backend Rails
* [x] Gateway Node
* [x] Comunicação entre serviços
* [ ] Frontend
* [ ] Autenticação
* [ ] Módulos de negócio
