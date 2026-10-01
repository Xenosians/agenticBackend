# Agentic Backend

Phoenix/Elixir durable API and orchestration boundary for the **Agentic Developer Hub / ITSM Platform**.

This repository owns the public application contract, authenticated users/chats, durable AI jobs, SurrealDB persistence, AI dispatch coordination, browser-facing approvals, internal AI callbacks, encrypted temporary credentials, and Gmail API OAuth2 outbound mail.

> **Boundary rule:** Phoenix owns durable product state. Model output is never authorization.

---

## System role

```text
Nim / Karax frontend
        |
        | public REST + browser session
        v
Phoenix / Elixir
        |
        +--> SurrealDB
        |
        +--> QueueWorker
                |
                | internal execute protocol
                v
            FastAPI AI
                |
                | heartbeat / durable completion
                v
            Phoenix
```

Repository boundaries:

```text
agenticFrontend
    Browser UX only.

agenticBackend
    Public API, application identity, chats, durable jobs,
    leases, approvals, persistence, internal service protocol,
    credential storage and outbound mail.

agenticAI
    Model reasoning, semantic validation, governed tool execution,
    provider integrations, AI-side execution-safety state.
```

---

## Current responsibilities

- public REST API;
- application registration/login/logout;
- email verification;
- forgot/reset-password flow;
- durable browser sessions and session revocation;
- authenticated chat ownership/history;
- SurrealDB-backed durable jobs;
- queue-worker dispatch;
- AI readiness gating;
- processing leases and attempts;
- heartbeat handling;
- restart-safe expired-processing reconciliation;
- authenticated AI completion callback;
- stale-attempt protection;
- duplicate completion acknowledgement;
- browser-facing job-scoped approval;
- structured result persistence;
- versioned JSON Schema contracts;
- encrypted temporary provisioned-account credential storage;
- Gmail API OAuth2 outbound email;
- centralized runtime configuration.

---

## Public API

Health:

```http
GET /api/health
```

### Authentication

```http
POST /api/v1/auth/register
POST /api/v1/auth/verify-email
POST /api/v1/auth/resend-verification
POST /api/v1/auth/login
GET  /api/v1/auth/me
POST /api/v1/auth/logout
POST /api/v1/auth/forgot-password
POST /api/v1/auth/reset-password
GET  /api/v1/auth/sessions
POST /api/v1/auth/sessions/:id/revoke
```

Authentication uses an HTTP-only browser session cookie plus CSRF protection for state-changing authenticated requests.

### Chats

```http
POST /api/v1/chats
GET  /api/v1/chats
GET  /api/v1/chats/:id
GET  /api/v1/chats/:id/history
```

Chats are user-owned. Job rows remain the canonical conversational turn records so chat history and execution history cannot silently diverge.

### Durable jobs

```http
POST /api/v1/jobs
GET  /api/v1/jobs/:id
POST /api/v1/jobs/:id/approve
```

A job may persist selected-agent metadata, proposed-tool metadata, assistant output, structured presentation cards, and failures.

Current durable job statuses are:

```text
pending
processing
waiting_approval
completed
failed
```

### Internal AI protocol

```http
POST /api/internal/v1/provisioned-accounts
POST /api/internal/v1/jobs/:id/heartbeat
POST /api/internal/v1/jobs/:id/completion
```

These endpoints are service-internal boundaries and use internal authentication.

---

## Durable job lifecycle

```text
pending
   |
   v
processing
   |
   +----------> waiting_approval
   |                  |
   |                  v
   |              processing
   |
   +----------> completed
   |
   +----------> failed
```

The backend validates legal transitions instead of allowing controllers/providers to set arbitrary states.

---

## Queue worker

`ItsmBackend.Jobs.QueueWorker` is an OTP worker that currently tracks at most one locally in-flight AI job.

Idle behavior:

```text
reconcile expired processing attempt
        |
        v
check AI readiness
        |
        v
claim oldest pending job
        |
        v
dispatch to FastAPI
        |
        v
expect 202 Accepted
```

Safety properties:

- jobs are atomically claimed;
- processing attempts carry lease metadata;
- heartbeat extends liveness;
- stale completion attempts are rejected;
- expired processing is failed closed when execution outcome may be ambiguous;
- ambiguous dispatch failures are not automatically duplicated;
- safe pre-dispatch failures may be requeued.

Phoenix/SurrealDB remain the durable source of truth.

---

## Conversation context

Optional bounded chat context can be projected into AI execution.

Configuration:

```env
AI_JOB_CONTEXT_ENABLED=false
AI_JOB_CONTEXT_MAX_TURNS=12
```

When enabled, Phoenix sends a bounded history window while excluding the current job.

The backend owns context selection; the frontend does not construct hidden AI history directly.

---

## SurrealDB

SurrealDB owns durable application state including:

- users/session-related application records;
- chats;
- durable jobs;
- provisioned-account metadata and encrypted temporary credentials.

Runtime settings are environment-driven rather than hardcoded.

Representative configuration:

```env
SURREALDB_URL=
SURREALDB_NAMESPACE=
SURREALDB_DATABASE=
SURREALDB_USERNAME=
SURREALDB_PASSWORD=
```

---

## Encrypted temporary credential vault

Provisioned account secrets can be encrypted before persistence.

Configuration:

```env
CREDENTIAL_ENCRYPTION_KEY_B64=
CREDENTIAL_KEY_VERSION=v1
CREDENTIAL_TTL_SECONDS=86400
```

The encryption key remains outside SurrealDB.

Temporary credentials are not intended to become general-purpose long-lived secret storage.

---

## Authentication and authorization

Current application identity support includes:

- registration;
- verification email;
- login;
- logout;
- session restoration;
- session listing;
- session revocation;
- forgot/reset-password flow;
- user-owned chat authorization;
- user-owned job authorization.

Broad enterprise RBAC/ABAC is not yet implemented.

---

## Gmail API OAuth2 mail

Outbound application mail supports:

```text
local
gmail_api
```

Development local mailbox:

```env
MAILER_MODE=local
```

Real Gmail REST transport:

```env
MAILER_MODE=gmail_api
MAIL_FROM_EMAIL=
MAIL_FROM_NAME=Agentic ITSM

GMAIL_CLIENT_ID=
GMAIL_CLIENT_SECRET=
GMAIL_REFRESH_TOKEN=
```

The backend stores the long-lived refresh token server-side.

Each real send performs:

```text
refresh token
    |
    v
Google OAuth token endpoint
    |
    v
short-lived access token
    |
    v
Swoosh Gmail REST adapter
```

No Gmail OAuth secret is exposed to the browser.

Mailer preflight:

```bash
mix itsm.mailer.preflight
```

Real isolated test:

```bash
mix itsm.mailer.preflight \
  --to you@example.com
```

### Multipart stakeholder mail

The mail boundary also supports a multipart message containing both:

```text
text/plain
text/html
```

The weekly SDLC workflow uses this path so Gmail renders a styled HTML engineering brief while retaining a plain-text/Markdown fallback.

```text
projectOps latest.md
        +
projectOps latest.html
        |
        v
Mix.Tasks.Itsm.Sdlc.WeeklyDigest
        |
        v
ItsmBackend.Mail.deliver_multipart/4
        |
        v
GmailOAuth.access_token()
        |
        v
Swoosh Gmail REST adapter
```

The HTML presentation layer does not bypass the existing OAuth transport or mail boundary.

---

## Runtime configuration

Runtime configuration is centralized through `config/runtime.exs` and `ItsmBackend.RuntimeConfig`.

Important groups include:

```text
Phoenix endpoint
AI service timeouts/base URL
queue-worker settings
internal service token
CORS origins
SurrealDB
credential encryption
application auth/session policy
frontend public URL
mail transport / Gmail OAuth
optional DNS clustering
```

Representative production values:

```env
PHX_SERVER=
PORT=
PHX_PUBLIC_URL=
PHX_BIND_IP=
SECRET_KEY_BASE=

AI_SERVICE_URL=
AI_RUN_TIMEOUT_MS=
AI_EXECUTE_TIMEOUT_MS=
AI_HEALTH_TIMEOUT_MS=
AI_READY_TIMEOUT_MS=

QUEUE_WORKER_ENABLED=
QUEUE_WORKER_POLL_INTERVAL_MS=
QUEUE_WORKER_LEASE_SECONDS=

ITSM_INTERNAL_JOB_TOKEN=
CORS_ALLOWED_ORIGINS=

APP_FRONTEND_URL=
AUTH_ADMIN_EMAILS=
```

See `.env.example` for the complete list.

---

## Weekly SDLC stakeholder digest

The backend is reused by the local `projectOps` subsystem for stakeholder delivery.

The weekly flow is:

```text
projectOps
    |
    +-- refresh explicit board
    +-- synchronize Notion
    +-- generate Markdown digest
    +-- generate Gmail-safe HTML digest
    |
    v
mix itsm.sdlc.weekly_digest
    |
    v
Gmail API OAuth2
```

Current validated behavior includes:

- recipient allowlisting through `projectOps/config/recipients.json`;
- dry-run mode with no delivery;
- real Gmail OAuth2 delivery;
- multipart `text/plain` + `text/html`;
- scheduled Windows -> WSL execution;
- runtime discovery for Python, Mix and Erlang/asdf;
- persistent scheduler logging;
- idempotent Notion synchronization.

This reporting workflow is operational tooling. It is not part of the AI execution-authority path.

---

## Versioned contracts

JSON Schema contracts live under:

```text
contracts/v1/
```

They cover public and internal service payloads, including:

```text
job create
job response
AI job accepted
AI completion
AI completion acknowledgement
AI execute request
tool proposal/common errors
```

Cross-repository changes should preserve:

```text
AI result
    |
    v
Phoenix completion validation
    |
    v
Surreal persistence/public contract
    |
    v
frontend decoding/rendering
```

---

## Structured results

Phoenix preserves structured AI presentation data through durable job state.

That allows the frontend to render tool/provider results as cards without depending on raw AI implementation details.

---

## Development

Install dependencies:

```bash
mix deps.get
```

Create/configure `.env` values for the runtime.

Start Phoenix:

```bash
mix phx.server
```

Development mailbox when `MAILER_MODE=local`:

```text
http://127.0.0.1:4000/dev/mailbox
```

---

## Tests

Run the suite:

```bash
mix test
```

Focused durable job tests:

```bash
mix test test/itsm_backend/jobs
```

AI-client tests:

```bash
mix test test/itsm_backend/ai_client
```

Runtime/config tests:

```bash
mix test test/itsm_backend/runtime_config_test.exs
mix test test/itsm_backend/cors_runtime_config_test.exs
```

Public/internal contract tests:

```bash
mix test test/contracts
mix test test/itsm_backend_web/controllers
```

---

## Important source layout

```text
config/
contracts/

lib/
  itsm_backend/
    ai_client/
    auth/
    chats/
    jobs/
    provisioned_accounts/
    storage/
    gmail_oauth.ex
    mail.ex
    mailer.ex
    runtime_config.ex
    surreal.ex

  itsm_backend_web/
    controllers/
    endpoint.ex
    router.ex

  mix/tasks/

test/
```

---

## Current deliberate limitations

The backend is already the durable integration spine, but it is still an MVP.

Current gaps include:

- public lifecycle has no first-class `denied` state;
- public lifecycle has no first-class `outcome_unknown` state;
- queue dispatch currently tracks one local in-flight job;
- browser lifecycle updates still rely on frontend polling;
- broad enterprise RBAC/ABAC is not complete;
- no distributed queue-worker coordination beyond durable Surreal state;
- deployment/bootstrap automation is not unified across all three repositories.

The single-inflight worker is currently a deliberate reliability choice for local hardware, not necessarily the final scaling model.

---

## Development rules

1. Phoenix owns durable product state.
2. Never treat a model/tool proposal as authorization.
3. Validate service boundaries with versioned contracts.
4. Do not silently retry ambiguous AI/provider side effects.
5. Preserve stale-attempt protection.
6. Keep secrets server-side.
7. Keep runtime configuration environment-driven.
8. Prefer explicit lifecycle transitions over free-form status mutation.
9. Preserve user/resource ownership checks.
10. Treat cross-repository serialization as part of the feature.

---

## Design summary

```text
Frontend owns interaction.
Phoenix owns durable application truth.
AI owns reasoning and governed execution.
SurrealDB owns durable backend persistence.
```
