# Agentic Backend

Phoenix durable API and orchestration boundary for the Agentic Developer Hub.

The backend owns durable application state, queues jobs for the AI service, validates completion callbacks, exposes job APIs to the frontend, and stores job state in SurrealDB.

> Development prototype.

## Responsibilities

- REST API boundary
- durable job creation
- durable job lookup
- QueueWorker dispatch
- AI readiness gating
- attempts and leases
- authenticated completion callback
- stale-attempt protection
- approval endpoint
- local frontend CORS
- SurrealDB ownership

## Architecture

```text
Karax
  -> POST /api/v1/jobs
Phoenix
  -> SurrealDB
QueueWorker
  -> FastAPI /v1/jobs/execute
FastAPI outbox
  -> Phoenix completion callback
Phoenix
  -> SurrealDB
Karax
  -> GET /api/v1/jobs/:id
```

## Requirements

- Elixir `~> 1.17`
- Phoenix `~> 1.8`
- Docker
- SurrealDB
- AI service on `127.0.0.1:8000`

## Start SurrealDB

From backend repository root:

```bash
docker compose up -d surrealdb
docker compose ps
```

Host endpoint:

```text
http://127.0.0.1:8001
```

Current development database:

```text
namespace: itsm
database: itsm
username: itsm_app
password: itsm_dev_2026
```

Fresh bootstrap:

```bash
docker exec -i itsm-surrealdb /surreal sql   --endpoint http://127.0.0.1:8000   --username itsm_app   --password itsm_dev_2026   --pretty <<'SQL'
DEFINE NAMESPACE itsm;
USE NS itsm;
DEFINE DATABASE itsm;
SQL
```

## Start Phoenix

```bash
cd /mnt/c/project/agenticBackend/itsm_backend
mix deps.get
mix phx.server
```

Service:

```text
http://127.0.0.1:4000
```

## Main API

```http
GET  /api/health
POST /api/v1/jobs
GET  /api/v1/jobs/:id
POST /api/v1/approvals/:approval_id/approve
POST /api/internal/v1/jobs/:id/completion
```

Create job:

```bash
curl -i   -X POST   http://127.0.0.1:4000/api/v1/jobs   -H 'Content-Type: application/json'   -d '{"user_id":"xenos","message":"hello"}'
```

With AI running:

```text
pending -> processing -> completed
```

## QueueWorker

Current development behavior:

1. poll AI `/ready`
2. claim oldest pending job
3. mark processing
4. increment attempt
5. assign lease
6. POST to AI
7. observe durable state until it leaves processing

Development values:

```text
poll interval: 1000 ms
lease: 300 s
AI URL: http://127.0.0.1:8000
```

## CORS

Allowed local frontend origins include:

```text
http://localhost:8080
http://127.0.0.1:8080
```

## SurrealDB warning

The repository has history with:

```text
surreal_data/itsm.db
surreal_data/database.db
```

Current Compose uses:

```text
rocksdb:/data/database.db
```

Do not switch paths casually.

## Known issues

- expired `processing` leases are not durably reclaimed yet
- `surreal_data/` should not be tracked in Git
- Compose uses `surrealdb/surrealdb:latest`
- namespace/database bootstrap is manual
- duplicate `ai_service_url` config exists
- accidental root file `0` should be removed
- development credentials are not production configuration

## Lease-recovery requirement

Current failure mode:

```text
processing job
  -> lease expires
  -> local inflight state clears
  -> durable row remains processing
  -> pending-only claim cannot recover it
```

Fix this atomically in durable state and coordinate with AI retry attempt handling.

## Before commit

```bash
mix format
mix compile --warnings-as-errors
mix test
```

Then verify create, fetch, completion ACK, duplicate completion, and stale-attempt behavior.

See the cross-repository `PROJECT_HANDOFF.md`.
