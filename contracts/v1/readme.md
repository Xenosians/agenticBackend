# Agentic ITSM Contracts v1

This directory contains the canonical cross-service data contracts for
the Agentic Developer Hub / ITSM platform.

The contracts use JSON Schema Draft 2020-12.

## Ownership

Phoenix / agenticBackend owns the canonical public and durable service
boundary.

Backend, AI, and Frontend implementations may define language-specific
DTOs or models, but those models are not the source of truth.

The JSON Schemas in this directory are the source of truth for data
crossing service boundaries.

## Layout

```text
contracts/v1/
├── common/
│   ├── error.schema.json
│   └── tool-proposal.schema.json
├── public/
│   ├── job-create-request.schema.json
│   ├── job-create-response.schema.json
│   └── job-response.schema.json
└── internal/
    ├── ai-job-execute-request.schema.json
    ├── ai-job-accepted.schema.json
    ├── ai-job-completion.schema.json
    └── ai-job-completion-ack.schema.json