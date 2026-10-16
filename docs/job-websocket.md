# Job updates over WebSocket

The browser receives job invalidations over a read-only Phoenix channel. It fetches the existing authenticated `GET /api/v2/jobs/:id` after joining and after each update. REST history and durable job storage remain authoritative; reconnects and polling recover missed notifications. Approvals, rejection, and job creation stay on the authenticated REST API with the existing CSRF rules.

## Browser connection

1. `POST /api/v2/jobs/socket-token` with the current session cookie and `X-CSRF-Token`, or existing bearer authentication. The response is `{token, expires_in: 120}` with `Cache-Control: no-store`.
2. Connect to `/socket/websocket?vsn=2.0.0`. Supply WebSocket subprotocols `phoenix` and `base64url.bearer.phx.<base64-without-padding-of-token>`, as supported by the installed Phoenix client. Never put the ticket, session cookie, or CSRF value in the URL.
3. Join `job:<job_id>` with an empty payload using the Phoenix v2 protocol. The join response and `job_updated` event contain only `{job_id, status, attempts}`. Status uses the v2 job lifecycle.
4. Refresh the authorized REST job snapshot on join, update, and reconnect. Obtain a fresh short-lived ticket for a new connection. Use a Phoenix heartbeat while connected.

The channel revalidates the persisted session and the same ownership rules as REST at join and before every event. An idle check closes revoked or expired subscriptions within 60 seconds. Browser origins must match the configured frontend origin by scheme, hostname, and port, including in development. The socket accepts no mutation commands and transmits no model answers, tool arguments, credential records, or passwords.

## AI progress connection

The AI service connects to `/ai_socket/websocket?vsn=2.0.0` with the existing `X-Internal-Token` request header. This credential must never be a URL parameter. It joins `ai_jobs:<job_id>` with `{attempt: positive_integer}` and sends the `progress` event with only `{stage: value}`. Allowed stage values are `routing`, `planning`, `executing`, `synthesizing`, and `waiting_provider`.

Both join and each progress message verify that the durable job is processing the exact attempt and its processing lease has not expired. The public job channel rechecks that binding and owner session before delivering `job_progress: {job_id, attempt, stage}`. Progress is an ephemeral activity hint and never changes the job status or proves a tool executed. Freeform text, extra properties, completion commands, stale attempts, and terminal jobs are refused. The existing HTTP completion callback/outbox remains the durable completion mechanism.

Notifications follow successful application persistence operations, including processing claims, completion callbacks, approval decisions, and lease recovery. Duplicate completion callbacks do not emit another update. Heartbeat lease renewals do not generate unnecessary UI updates. A missed notification does not rerun inference or a tool.
