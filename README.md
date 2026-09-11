# Agentic Backend

Phoenix durable API and orchestration boundary for the Agentic Developer Hub.

The backend owns the public application contract, durable job lifecycle, SurrealDB persistence, AI dispatch coordination, completion validation, restart-safe lease recovery, versioned service contracts, and browser-facing approval flow.

> Development prototype. Phoenix is the public boundary; model output is never authorization.

## Responsibilities

- REST API boundary
- durable job creation and lookup
- SurrealDB-owned job persistence
- QueueWorker dispatch
- AI readiness gating
- processing leases and attempt metadata
- restart-safe expired-processing recovery
- authenticated AI completion callback
- stale-attempt protection
- duplicate completion acknowledgement
- browser-facing job-scoped approval
- versioned JSON Schema service contracts
- centralized validated runtime configuration
- local frontend CORS
- durable result ownership

## Architecture

```text
Karax
  |
  | public REST
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
  | authenticated completion callback
  v
Phoenix
  |
  v
SurrealDB
  ^
  |
  | durable job read
Karax