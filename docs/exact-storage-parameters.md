# Exact storage parameters

The shared SurrealDB JSON RPC decoder interprets some string values as SurrealQL values before executing the query. A user message such as `VPN: users cannot connect` can become record text `VPN:users`, an IPv6 string can lose components, and an ISO-looking text field can become a datetime. Nested proposal arguments are affected too. JSON returned over HTTP can conceal the changed database type, so a normal JSON roundtrip alone cannot verify the storage contract.

`ItsmBackend.Surreal.Bindings` now binds JSON-compatible application values using generated wire parameters and inline `encoding::json::decode` expressions. User values never enter query source. The binder adds no query statements or result entries, and indexed predicates retain their index plans. A failed `LET` prelude was deliberately avoided: SurrealDB can continue executing later statements after a failed binding statement.

Only trusted schema timestamps use native `DateTime` values or `Surreal.datetime` / `Surreal.datetime_fields`. Auth sessions/tokens, chats, jobs and encrypted credential metadata declare those fields explicitly. Adjacent user text that resembles a date remains text. Integer bounds, nesting, UTF-8, string map keys and supported JSON value types are validated before configuration lookup, authentication or network dispatch. Invalid values return a sanitized `invalid_surreal_parameters` error; they are never stringified or retried with a weaker representation.

The lexical rewriter covers the application's fixed trusted query forms: ordinary parameter tokens, quoted strings/identifiers (including record identifiers), line/block comments, `LET` locals with block scoping, and the existing transaction statements. It is not a general SurrealQL compiler. The current storage query inventory contains no `FOR` declarations, function parameters or regex literals that shadow parameter names. Do not introduce those forms without extending the lexer and real-database regression coverage. Query source remains trusted application code, never model or request text.

Existing mail JSON envelopes remain valid; the binder preserves their text and the caller still decodes them once inside its existing statement. Existing datetime casts and atomic approval/attempt predicates remain authoritative.

The chat boundary explicitly resolves the existing public storage-record alias (`chat:<canonical-id>`, including the quoted numeric form) to its generated canonical identity. Owner checks still apply. History and archive use that resolved identity; no generic user text is reinterpreted as a record id.

This change prevents new coercion. It does not recover information already lost in historical rows, migrate application data, rewrite an old approval, or permit retrying an uncertain side effect. Reconcile affected legacy jobs and proposals using their original authorized evidence. Incompatible historical approval bindings remain unresolved rather than being silently upgraded.

Regression coverage includes exact punctuation/IPv6/ISO text, nested typed datetime fields and arrays, integer types, real job/chat roundtrips, exact approval compare-and-set and changed-target rejection, invalid multi-statement mutation bindings, index plans, comments/literals, local-variable scopes and original response ordering.
