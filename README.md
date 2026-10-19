# Agentic Backend

Phoenix/Elixir API for the Agentic Developer Hub and ITSM platform. It owns authentication, chats, durable jobs, and the browser-facing approval lifecycle, with application data stored in SurrealDB.

> **Project status:** SRS 1.8 MVP candidate. The durable product path is implemented, but MVP v1.0 is not declared until the cross-repository release gate has current live and browser evidence.

## Features

- Registration, email verification, login, password reset, session restoration, and session revocation.
- User-owned chats, history, and durable AI jobs.
- Queue dispatch with leases, heartbeats, validated completion callbacks, and stale-attempt protection.
- Approve or reject the exact persisted job proposal, with structured results and explicit failure, denial, and unknown-outcome states.
- Authenticated WebSocket status updates for the browser and bounded progress events from the AI runtime, with REST recovery after reconnect.
- A durable account → Jira ticket workflow with separately bound approvals, verified provider results, and completion notifications through the existing mail outbox.
- Authenticated model/harness/dataset commands proxied to the AI service; ownership comes from the session and mutations require CSRF.
- Backend/AI health and integration status endpoints.
- Local development mail, Brevo HTTPS API or Gmail OAuth2 delivery, plus a durable mail outbox.
- Encrypted temporary account credentials and versioned JSON contracts between services.

## How the repositories fit together

```text
agenticFrontend (Nim/Karax browser)
    -> agenticBackend / itsm_backend (this API)
        -> SurrealDB (application persistence)
        -> agenticaiPersonal / itsm-agent (inference and guarded tools)
```

The browser calls Phoenix. Phoenix owns product state and derives user identity from its session. The AI runtime owns model execution, tool policy, and exact-action approval safety. External provider credentials and execution authority stay server-side.

## Stack

Elixir `~> 1.17`, Phoenix `~> 1.8.13`, Bandit, Req, Swoosh, and SurrealDB. Docker Compose is provided for a local SurrealDB service; the API and AI services run separately.

## Local setup

Install a compatible Elixir/Erlang environment and provide a running SurrealDB instance. Run commands from this repository.

```bash
mix deps.get
cp .env.example .env
```

Fill the required values in `.env` and export them into the shell, for example using direnv with the supplied `.envrc`. Phoenix reads environment variables; it does not load `.env` itself. Remove unused blank optional overrides rather than exporting them as empty values.

Use [.env.example](.env.example) and [runtime configuration](config/runtime.exs) for the full configuration. The main groups are:

| Settings | Purpose |
| --- | --- |
| `SURREALDB_*` | Database URL, namespace, database, and credentials |
| `ITSM_INTERNAL_JOB_TOKEN` | Same private token as the AI runtime |
| `AI_SERVICE_URL` | AI origin; development default is `http://127.0.0.1:8000` |
| `CREDENTIAL_ENCRYPTION_KEY_B64` | Persistent encryption key: exactly 32 random bytes, base64 encoded |
| `APP_FRONTEND_URL`, `CORS_ALLOWED_ORIGINS` | Frontend origin and browser access policy |
| `AUTH_COOKIE_*` | Cookie policy appropriate to the deployment |
| `MAILER_MODE` | `local` for development, or configured `brevo_api` / `gmail_api` |

For the included database container, populate the additional variables required by [docker-compose.yaml](docker-compose.yaml), then run:

```bash
docker compose up -d surrealdb
```

Initialize the application schema before starting Phoenix:

```bash
mix itsm.schema.ensure
mix phx.server
```

Development defaults to `http://127.0.0.1:4000`. Health is available at `/api/health`; local development mail is at `/dev/mailbox`. Start the AI runtime separately for chat execution and model/dataset management. Production also requires endpoint and secret settings from the runtime configuration.

## API and contracts

| Surface | Routes |
| --- | --- |
| Identity and sessions | `/api/v1/auth/*` |
| Chats | `/api/v1/chats`, `/api/v1/chats/:id/history` |
| Job creation | `POST /api/v1/jobs` |
| Current job/history reads and decisions | `/api/v2/jobs/:id`, `/api/v2/jobs/:id/approve`, `/api/v2/jobs/:id/reject`, `/api/v2/chats/:id/history` |
| User extensions | `GET/POST /api/v1/extensions` |
| Integration status | `GET /api/v1/integrations` |
| Internal AI protocol | `/api/internal/v1/*` |

The current v2 public job contract includes `pending`, `processing`, `waiting_approval`, `completed`, `failed`, `denied`, and `outcome_unknown`. Legacy v1 routes remain available. See the [v1 contract guide](contracts/v1/readme.md) and [v2 schemas](contracts/v2) before changing shared payloads.

Approval decisions require the authenticated owner and browser CSRF protection.
Human rejection appears as `denied` with an explicit user-rejection explanation
and a persisted `approval_execution.execution_status` of `rejected`; legacy v1
projects that job to `failed`. The AI atomically decides between rejecting a
pending proposal and executing it. Rejection cannot cancel an action that has
already started: Phoenix records the returned execution outcome instead.
Unclear decision delivery becomes `outcome_unknown`, and terminal decisions
cannot be submitted again. Approval persistence compares the original attempt
and proposal so a late response cannot overwrite another terminal outcome.
Internal decision requests authenticate to the AI and disable automatic retries.

## Tests and checks

With the database reachable and the required environment loaded:

```bash
mix test
mix precommit
```

Tests initialize schema in a separate database: `SURREALDB_DATABASE` plus `_test`, or `SURREALDB_TEST_DATABASE`. It must differ from the development database, and the configured account needs permission to create the test database and schema. Test setup does not copy production records. `mix precommit` also compiles with warnings as errors, checks dependencies, and formats source files.

## Current boundaries

- The queue worker tracks one in-flight job per process; this is not a complete distributed worker platform.
- WebSocket updates are notifications; authenticated REST reads and durable storage remain authoritative. Unknown execution outcomes require reconciliation instead of automatic mutation retries.
- Ownership/session checks are implemented; broad enterprise RBAC/ABAC remains incomplete.
- Model and dataset extensions are implemented in the AI service. They do not replace SurrealDB or grant new tool authority.
- Reference retrieval currently uses local full-text search. n8n/workflow support is manifest validation only, with no runner or webhook registration.
- User model/dataset selection leaves the networking specialist's existing model and context unchanged.
- Provider availability and real email delivery depend on deployment configuration. There is no unified deployment command for all three repositories.
- A Brevo delivery call makes one request per attempt. The outbox retries only explicit rate-limit rejections; lost acknowledgements, uncertain sends and expired processing claims require reconciliation and are never automatically resent. `sent` means provider acceptance, not confirmed inbox delivery.

## Source references

- [Routes](lib/itsm_backend_web/router.ex)
- [Runtime configuration](config/runtime.exs)
- [Database schema](priv/surreal/schema.surql)
- [Job lifecycle and worker](lib/itsm_backend/jobs)
- [Browser and AI WebSocket protocol](docs/job-websocket.md)
- [Dependent approval validation](lib/itsm_backend/jobs/workflow_continuation.ex)
- [Extension proxy](lib/itsm_backend_web/controllers/extension_controller.ex)
- [Development guidelines](AGENTS.md)
