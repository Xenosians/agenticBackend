# Requested workflow contracts

`POST /api/v1/jobs` accepts an optional `workflow_contract` alongside the existing chat, message and submission identity. Clients can let a user explicitly review operations, targets and dependencies. The AI must compare the complete returned plan with these obligations before dispatch. Free-text submissions remain supported when the field is absent or null.

```json
{
  "version": 1,
  "steps": [
    {
      "id": "account",
      "capability": "account_create",
      "grounded_arguments": {"given_name": ["Reviewed"], "family_name": ["User"]},
      "after_success_of": null
    },
    {
      "id": "ticket",
      "capability": "ticket_create",
      "grounded_arguments": {"project_key": ["REVIEWED-PROJECT"]},
      "after_success_of": "account"
    }
  ]
}
```

Use registered capability names and their actual grounded argument roles. Values in the example are illustrative, not deployment configuration. The AI rejects unsupported capability or argument contracts. An empty argument map pins only the operation and dependency; existing semantic grounding, policy and approvals still apply. A requested contract cannot authorize a tool, supply a credential, replace an exact approval, or prove completion.

Contracts have 1–8 steps. Step IDs and capabilities must be unique; a dependency may only reference an earlier step. Each step has exactly the four keys shown. Grounded argument names use ASCII identifiers, with at most 32 names, 1–16 string values per name, and 1–1,024 Unicode code points per value. Targets and their list order are preserved exactly. The full compact UTF-8 contract is limited to 32,768 bytes.

Phoenix computes `workflow_contract_hash`; public clients cannot supply it. The digest is lowercase SHA-256 of compact UTF-8 JSON for this array projection, with Unicode left unescaped and argument keys sorted in ASCII order:

```text
["itsm-requested-workflow.v1", 1,
 [[step.id, step.capability,
   [[argument_key, exact_value_list], ...], step.after_success_of], ...]]
```

Both fields persist with the owner-scoped job and appear in job reads and user history. Contract-bound create acknowledgements echo this persisted pair; the browser verifies it against the pinned request before clearing pending submission recovery. Legacy create acknowledgements omit the pair. Reusing a submission identity requires the same chat, message and workflow; changes return `409 submission_conflict`. Lost create acknowledgements must be recovered with that identity. Ordinary updates and approval completion/continuation cannot replace either field. Historical rows without the fields remain readable.

Queue dispatch sends the same contract and digest to the internal AI job endpoint. A configured AI client without the workflow-aware callback fails explicitly instead of dropping obligations. This known pre-dispatch failure is saved as `failed` with reason `workflow_client_unsupported`; it is not retried through a legacy callback. If saving that disposition fails, only the same claim's persistence is retried. Unknown HTTP/provider outcomes retain their existing reconciliation path. JSON Schema describes the wire structure; domain validation additionally enforces uniqueness, dependency order, total size and digest correlation. This protocol establishes an execution constraint, not live provider acceptance or an MVP release certificate.

The same disposition rule applies when the AI execution endpoint rejects a request with HTTP 400, 401, 403, 404, 405, 413, 415 or 422. The job becomes `failed` with the sanitized `ai_request_rejected` reason and HTTP status; the unchanged request is not repeatedly dispatched. HTTP 429 retains its known-rejection requeue path. HTTP 408, 409, unexpected acknowledgements and transport failures do not prove that execution was rejected: the attempt stays processing until completion or lease-expiry reconciliation, without automatic redispatch. Dispatch error logs retain only explicit protocol reason categories and valid HTTP status integers. Unexpected or malformed acknowledgements, schema-reflected values, chat-context projection failures and transport errors cannot copy response/input bodies or arbitrary exception metadata into those diagnostics; unknown reasons receive a stable generic category. This logging restriction does not change job disposition or establish execution success.
