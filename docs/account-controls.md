# Account controls

The Settings view uses authenticated, owner-scoped controls. Cookie-session writes require the `X-CSRF-Token` returned by sign-in or `/api/v1/auth/me`. Bearer tokens use the same persisted identity and session checks.

`GET /api/v1/auth/preferences` returns `{"preferences":{"task_completed":true,"theme":"dark","accent":"mono"}}`. `PUT` to the same endpoint accepts any non-empty subset of those three settings and returns all saved settings; settings left out keep their saved values. `task_completed` takes a JSON boolean, `theme` one of `dark`, `light` or `system`, and `accent` one of `mono`, `blue`, `teal`, `green`, `amber`, `rose` or `violet`. Any other value, an empty body, unrecognized arguments or query parameters return 422. Absent stored settings default to the values above; a stored value outside these lists and unavailable reads return 503 rather than claiming a value. An unconfirmed write is read back and succeeds only if every stored value matches the request.

Appearance settings follow the owner across browsers because the server stores them; the frontend keeps nothing in browser storage.

The preference controls new automatic **completed-task** notifications only. The deployment's `TASK_COMPLETION_MAIL_ENABLED` remains the master switch. Authentication, approval, failure, denial and reconciliation mail, explicitly requested notifications, and the separately managed Friday report are unaffected. Already queued outbox messages are neither cancelled nor resent. Saving a preference does not dispatch or replay tasks or mail.

`POST /api/v1/auth/sessions/revoke-others` accepts no arguments and returns `{"status":"revoked","revoked_count":2}`. The count comes from confirmed active sessions changed in the transaction. The exact current session remains active, and another owner's sessions, expired sessions and already revoked sessions are excluded. Repeating the operation after success normally reports zero. A lost or malformed database receipt returns 503 `session_revoke_unconfirmed`, including when revocation may have applied: reload the session list before deciding whether another action is needed. Revoked sockets revalidate through the existing persisted-session boundary.

These controls do not change passwords, add passkeys or step-up authentication, promote reviewers, or manage provider credentials.

## Temporary password hand-over

An approved account creation, password reset or local mailbox saves a temporary password encrypted in `credential_secret`; it is never mailed, because the new person's mailbox does not exist yet. The person who asked for it reveals it once inside Janus and hands it over; the user changes it at first sign-in.

`POST /api/v2/jobs/:job_id/credentials/:credential_id/reveal` takes `{"password": "<the caller's own Janus password>"}` and needs a session plus `X-CSRF-Token` (or a bearer token). It returns `{"credential_id", "subject", "temporary_password", "must_change_at_first_sign_in": true}` with `Cache-Control: no-store`. `subject` is `{"kind": "directory_account", "user_id", "email"?}` or `{"kind": "mailbox", "email"}`.

Authorization comes only from Phoenix's records (`ItsmBackend.CredentialHandover`):

- the caller owns the job;
- an approval outcome Phoenix recorded for that job, either the latest `approval_execution` or an earlier step in `approval_history`, is `succeeded` and `approved` and names this `credential_id`;
- the credential is an unexpired, unrevealed `temporary_password`;
- it decrypts under authenticated data rebuilt from its stored identity and the current key version.

One conditional update marks it consumed (`consumed_at`, `consumed_by`) and erases the ciphertext, so a second or concurrent reveal fails.

| Status | `error` | Meaning |
| --- | --- | --- |
| 401 | `invalid_credentials` | Wrong password; counts against the sign-in limit |
| 403 | `forbidden` | Another user's request |
| 404 | `job_not_found` | No such request |
| 404 | `credential_not_found` | Not named by a succeeded, approved outcome of this request |
| 409 | `credential_unreadable` | The ciphertext does not match its stored identity or key version |
| 410 | `credential_already_revealed`, `credential_expired` | Already handed over, or past `expires_at` |
| 422 | `invalid_request` | Body other than `password` |
| 429 | `sign_in_rate_limited` | Too many recent password failures (`Retry-After` is set) |
| 503 | `credential_reveal_failed` | Storage or vault unavailable; nothing was revealed or consumed |

Chat history marks the answer with `"credential_handover": {"credential_id": "..."}` (identity only) so a reloaded chat still offers the reveal; the endpoint decides whether it is still available. Logs carry ids only. A lost password needs a new approved password reset.
