# Operations snapshot and inference measurements

`GET /api/v1/operations?limit=25` requires the user's authenticated session or
bearer token. It returns counts over all of that owner's durable jobs and a
bounded recent-job list (`limit` is 1–100). It cannot inspect another user's
queue and does not expose requests, answers, arguments, recipients or raw logs.
This read never executes, retries, approves or cancels work.

The response schema is `operations-snapshot.v1`. Every lifecycle status has a
count. A successful empty query establishes zero; storage failure returns 503
without invented counts. `observed_at` is the request's observation time, not an
atomic database-wide snapshot guarantee. Counts, recent jobs and measurements
are separate bounded reads and may advance while jobs run.

Each job contains its canonical `job_id`, optional `chat_id` and specialist,
status, attempt, submission/claim/completion timestamps, and observations for
only its current attempt. `queue_wait_ms` measures submission to the current
claim. `elapsed_ms` measures submission to completion for terminal jobs, or to
the observation time for active jobs; it includes human approval waits. Missing
or contradictory timestamps remain null.

`metrics` contains at most 64 content-free inference events. `metrics_truncated`
states whether further events exist. An empty list means no measurements were
recorded, not that the job used no time or tokens. Call durations can overlap;
summing them is not an end-to-end latency measurement. Token counts, scheduler
wait, execution and time to first token remain null when the adapter did not
observe them. This API does not estimate billing cost or claim provider health.

## Internal collection

`POST /api/internal/v1/jobs/:id/metrics` uses the same internal service credential
as durable-job callbacks. The body requires `attempt`, a 32-hex `event_id`,
`stage`, `operation`, `adapter`, `outcome` and measured `duration_ms`. Optional
nullable fields are `role`, `repair_of`, `queue_ms`, `execution_ms`,
`first_token_ms`, `generated_tokens`, `estimated_input_tokens`,
`request_token_budget`, `output_token_cap` and `dropped_messages`. Unknown fields
are rejected. The server derives the owner from the job and records its own
timestamp. Timing values are finite, nonnegative and at most one day; counts
are nonnegative integers up to one billion.

The exact current attempt is checked again in the write transaction. A current
attempt can finish while its final telemetry arrives, so a terminal lifecycle
state is not itself grounds for rejection. No observation updates job state,
approvals, permissions, results or provider receipts.

The event identity is unique within a job and attempt. The same payload returns
the immutable existing event; changed data under that identity returns 409.
An ambiguous write is accepted only after exact stored readback, otherwise 503
reports `metric_outcome_unknown`. Retrying telemetry uses the same event
identity and never repeats an inference or a tool operation. Unavailable
telemetry must not change business execution outcomes.

The normal database schema includes `job_metric` and owner/job/attempt indexes.
Apply `priv/surreal/schema.surql` when deploying to a strict database. Historical
jobs have no retroactively fabricated stage measurements.
