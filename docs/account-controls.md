# Account controls

The Settings view uses authenticated, owner-scoped controls. Cookie-session writes require the `X-CSRF-Token` returned by sign-in or `/api/v1/auth/me`. Bearer tokens use the same persisted identity and session checks.

`GET /api/v1/auth/preferences` returns `{"preferences":{"task_completed":true,"theme":"dark","accent":"mono"}}`. `PUT` to the same endpoint accepts any non-empty subset of those three settings and returns all saved settings; settings left out keep their saved values. `task_completed` takes a JSON boolean, `theme` one of `dark`, `light` or `system`, and `accent` one of `mono`, `blue`, `teal`, `green`, `amber`, `rose` or `violet`. Any other value, an empty body, unrecognized arguments or query parameters return 422. Absent stored settings default to the values above; a stored value outside these lists and unavailable reads return 503 rather than claiming a value. An unconfirmed write is read back and succeeds only if every stored value matches the request.

Appearance settings follow the owner across browsers because the server stores them; the frontend keeps nothing in browser storage.

The preference controls new automatic **completed-task** notifications only. The deployment's `TASK_COMPLETION_MAIL_ENABLED` remains the master switch. Authentication, approval, failure, denial and reconciliation mail, explicitly requested notifications, and the separately managed Friday report are unaffected. Already queued outbox messages are neither cancelled nor resent. Saving a preference does not dispatch or replay tasks or mail.

`POST /api/v1/auth/sessions/revoke-others` accepts no arguments and returns `{"status":"revoked","revoked_count":2}`. The count comes from confirmed active sessions changed in the transaction. The exact current session remains active, and another owner's sessions, expired sessions and already revoked sessions are excluded. Repeating the operation after success normally reports zero. A lost or malformed database receipt returns 503 `session_revoke_unconfirmed`, including when revocation may have applied: reload the session list before deciding whether another action is needed. Revoked sockets revalidate through the existing persisted-session boundary.

These controls do not change passwords, add passkeys or step-up authentication, promote reviewers, or manage provider credentials.
