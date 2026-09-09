# Agentic Backend

Phoenix durable API and orchestration boundary for the Agentic Developer Hub.

The backend owns the public application contract, durable job lifecycle, SurrealDB persistence, AI dispatch coordination, completion validation, and browser-facing approval flow.

> Development prototype. Phoenix is the public boundary; model output is never authorization.

## Responsibilities

- REST API boundary
- durable job creation and lookup
- SurrealDB-owned job persistence
- QueueWorker dispatch
- AI readiness gating
- attempt and lease metadata
- authenticated AI completion callback
- stale-attempt protection
- duplicate completion acknowledgement
- browser-facing job-scoped approval
- transitional direct approval endpoint
- local frontend CORS
- durable result ownership

## Architecture

```text
Karax
  |
  | POST /api/v1/jobs
  v
Phoenix
  |
  v
SurrealDB
  ^
  |
QueueWorker
  |
  | POST /v1/jobs/execute
  v
FastAPI / AI runtime
  |
  | durable completion outbox
  | POST /api/internal/v1/jobs/:id/completion
  v
Phoenix
  |
  v
SurrealDB
  ^
  |
  | GET /api/v1/jobs/:id
Karax
```

Approval path:

```text
AI proposes mutation
  |
  v
Phoenix persists job as waiting_approval
  |
  v
Browser POST /api/v1/jobs/:job_id/approve
  |
  v
Phoenix loads trusted approval_id from persisted proposal
  |
  v
AI approval execution
  |
  v
Phoenix persists completed job/result
```

The browser does not supply the privileged `approval_id` in the primary approval flow.

## Requirements

- Elixir `~> 1.17`
- Phoenix `~> 1.8`
- Docker
- SurrealDB
- AI service on `127.0.0.1:8000`

## Start SurrealDB

From the backend repository root:

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
docker exec -i itsm-surrealdb /surreal sql \
  --endpoint http://127.0.0.1:8000 \
  --username itsm_app \
  --password itsm_dev_2026 \
  --pretty <<'SQL'
DEFINE NAMESPACE itsm;
USE NS itsm;
DEFINE DATABASE itsm;
SQL
```

Development credentials are not production configuration.

## Start Phoenix

```bash
cd /mnt/c/project/agenticBackend
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
POST /api/v1/jobs/:id/approve

POST /api/internal/v1/jobs/:id/completion
```

Transitional compatibility/debug routes also exist:

```http
POST /api/v1/agent/run
POST /api/v1/approvals/:approval_id/approve
```

The job-scoped approval endpoint is the preferred browser path.

## Create a job

```bash
curl -i \
  -X POST \
  http://127.0.0.1:4000/api/v1/jobs \
  -H 'Content-Type: application/json' \
  -d '{"user_id":"demo-user","message":"hello"}'
```

Typical no-approval lifecycle:

```text
pending
  -> processing
  -> completed
```

Approval lifecycle:

```text
pending
  -> processing
  -> waiting_approval
  -> completed
```

Failure may transition the job to:

```text
failed
```

## Durable job approval

The preferred approval request is:

```http
POST /api/v1/jobs/:job_id/approve
```

Phoenix:

1. loads the durable job
2. requires `waiting_approval`
3. extracts the trusted `approval_id` from the persisted proposal
4. calls the AI approval endpoint
5. merges the returned execution data into the durable job result
6. transitions the job to `completed`
7. persists the final job before returning it to the browser

The browser therefore identifies the job, not the privileged internal approval record.

Important safety property:

```text
browser job_id
  != authority to invent tool arguments
  != authority to choose approval_id
```

## Approval reliability boundary

The AI service now maintains restart-persistent approval execution state in its own SQLite runtime store.

Its execution state machine is:

```text
pending
  -> executing
      -> approved
      -> failed
```

A repeated approval of an already approved AI approval replays the stored result instead of re-running the mutation.

An approval left in `executing` after an ambiguous crash is not automatically returned to `pending`, because the side effect may already have occurred.

Phoenix still owns the public durable job lifecycle. A richer application-owned approval entity in SurrealDB, including approver identity/audit metadata, remains a future hardening step.

## QueueWorker

Current development behavior:

1. poll AI `/ready`
2. claim oldest eligible pending job
3. transition it to `processing`
4. increment attempt
5. assign a processing lease
6. POST the execution request to AI
7. observe durable state until it leaves `processing`

Development values include:

```text
poll interval: 1000 ms
lease: 300 s
AI URL: http://127.0.0.1:8000
```

The dispatch path intentionally avoids blindly requeueing an ambiguous post-dispatch network failure because Python may already be executing the request.

## Completion handshake

The normal completion path is:

```text
AI completes work
  -> AI persists immutable completion payload locally
  -> AI calls authenticated Phoenix completion endpoint
  -> Phoenix validates job + attempt + state
  -> Phoenix persists terminal result
  -> Phoenix acknowledges
  -> AI removes outbox entry
```

The backend rejects stale attempts and acknowledges valid duplicate same-terminal completions.

## CORS

Allowed local frontend origins include:

```text
http://localhost:8080
http://127.0.0.1:8080
```

The browser should call Phoenix, not FastAPI.

## SurrealDB ownership

Phoenix owns durable application state.

```text
Frontend
  X no SurrealDB access

AI
  X no direct Phoenix SurrealDB queries

Phoenix
  -> SurrealDB
```

Local SurrealDB data is runtime state and should not be tracked in Git.

## Current reliability gap: lease recovery

Expired `processing` jobs are not yet durably reclaimed.

Current failure mode:

```text
processing job
  -> lease expires
  -> QueueWorker clears local inflight tracking
  -> durable row may remain processing
  -> pending-only claim cannot recover it
```

Recovery needs explicit durable state transition/reconciliation rather than merely clearing local worker memory.

## Known issues

- expired `processing` leases are not durably repaired/requeued yet
- Compose currently uses `surrealdb/surrealdb:latest`
- namespace/database bootstrap is manual
- duplicate AI service configuration should be cleaned up
- accidental zero-byte root file `0` may still need removal
- development credentials are not production configuration
- approval execution is safer and restart-persistent in AI, but full Phoenix/SurrealDB approval audit ownership is not complete
- WebSocket/PubSub user delivery is not implemented; polling is the current frontend delivery path

## Before commit

```bash
mix format
mix compile --warnings-as-errors
mix test
```

Then verify the important integration paths:

```text
create job
fetch job
completion ACK
duplicate completion
stale attempt rejection
waiting_approval
job-scoped approval
completed approved mutation
```

See the project SRS for the cross-repository architecture.
