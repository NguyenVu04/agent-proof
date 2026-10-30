# AgentProof

AgentProof helps teams inspect AI agent runs, verify behavior against policies and expected workflows, and gate releases with evidence-backed evaluations.

> **Status: design with a partial implementation.** This README summarizes the intended product. [`docs/architecture/ARCHITECTURE.md`](docs/architecture/ARCHITECTURE.md) holds the architecture and its decisions, and [`docs/USECASE_SPECIFICATION.html`](docs/USECASE_SPECIFICATION.html) holds the requirements. The repository holds the backend and frontend shells, the schema and seed, and the local Docker stack. It has no public endpoints, maintainers' contact details, or released software. Commands and APIs described as proposed below are contracts to implement, not currently verified interfaces.

## Status and ownership

| Field | Current state |
|---|---|
| Maturity | Design / pre-implementation |
| Ownership | Not specified in the project materials |
| Contact and on-call | Not established; required before operating a shared service |
| Source of record and issue tracker | Not supplied |

## Contents

- [Overview](#overview)
- [Architecture](#architecture)
- [Getting started](#getting-started)
- [Configuration](#configuration)
- [Usage](#usage)
- [Development](#development)
- [Testing](#testing)
- [Build and deployment](#build-and-deployment)
- [Observability](#observability)
- [Security](#security)
- [Compliance and data handling](#compliance-and-data-handling)
- [Service levels and support](#service-levels-and-support)
- [Versioning and compatibility](#versioning-and-compatibility)
- [Governance](#governance)
- [Roadmap](#roadmap)
- [Contributing](#contributing)

## Overview

An agent may complete a task while skipping an approval, making an unnecessary sensitive-data request, repeating retrievals, or acting on unsupported evidence. Output-only evaluation misses these execution failures. AgentProof examines the full trajectory and links each confirmed finding to trace spans, policy versions, workflow requirements, or reproducible measurements.

It accepts OpenTelemetry-compatible agent traces, normalizes framework-specific events, runs structured checks, retrieves bounded contextual evidence for semantic critics, and presents the result in an investigation UI. The same evaluation results can inform a CI regression gate. Outcome success and behavioral correctness remain separate statuses.

### Capabilities

- Inspect traces, tool calls, retrievals, handoffs, approvals, findings, and their supporting evidence.
- Detect invalid arguments, wrong tools, loops, missing steps, policy violations, unsupported conclusions, and cost regressions.
- Compare expected and actual trajectories, identify possible causes, and record reviewer decisions.
- Compare agent versions on versioned datasets and return `PASS`, `FAIL`, or `ERROR` to an existing CI pipeline.

### Non-goals

- Hosting or executing arbitrary customer agent code in the initial release; evaluation cases run in the customer's own CI environment.
- Replacing general-purpose telemetry storage, CI services, or human review of ambiguous findings.
- Automatically rewriting prompts or agent code, or guaranteeing formal proof of unrestricted natural-language behavior.
- Fine-tuning LLMs as part of this design.

## Architecture

```mermaid
flowchart TD
    B["Browser"] --> FE["frontend, Next.js"]
    FE -->|"/api rewrite"| G["Envoy API gateway"]
    A["CI client"] --> G
    T["Agent telemetry over OTLP HTTP"] --> G
    U["Auth0"] -. "sign-in" .-> FE
    U -. "signing keys" .-> API
    G --> API["api"]
    API --> P[("PostgreSQL and job queue")]
    API --> B2[("Blob store")]
    P -. "jobs" .-> W["worker-analysis"]
    P -. "jobs" .-> C["worker-semantic"]
    W --> P
    C --> P
    C --> V[("Qdrant")]
    C --> L["Ollama"]
```

PostgreSQL is authoritative for canonical business data, and it holds the job queue through Procrastinate. Qdrant holds semantic embeddings as a projection that must be rebuildable from versioned records. An S3-compatible blob store holds raw batches and large span fields. From Phase 2, ClickHouse stores all spans, including evaluation traces, and usage metrics; PostgreSQL keeps the control plane and every decision record (use case specification, C-01). One backend image runs three process roles: `api`, `worker-analysis`, and `worker-semantic`. Next.js serves the UI and stands in front of Envoy, so Envoy handles only API and OTLP traffic. A shared environment also needs a reverse proxy in front of Next.js. [`ARCHITECTURE.md`](docs/architecture/ARCHITECTURE.md) gives the views, the decisions, and the work still to do. [`docs/architecture/adr/`](docs/architecture/adr/README.md) holds the ADRs.

### Components

| Component | Responsibility | Location |
|---|---|---|
| Web | Next.js: Trace Explorer, expected-versus-actual view, evaluation comparison, browser session | `frontend/` |
| `api` | Project authorization, commands, queries, reviews, gate results. OTLP HTTP ingestion: authenticate, validate, scrub, redact, persist, defer jobs | `backend/src/api/` |
| Workers | Normalizer, detectors, evidence validation, critics, evaluation | `backend/src/tasks/` (planned) |
| Application | Use cases and ports | `backend/src/application/` (planned) |
| Domain | Canonical trace, policy compiler, detectors, evidence, evaluation, gate | `backend/src/domain/` (empty today) |
| Infrastructure adapters | PostgreSQL, ClickHouse, blob store, Qdrant, LLM | `backend/src/infrastructure/` |
| CI client | Go binary and a thin GitHub Action | `clients/` (planned) |

The canonical hierarchy includes agent, LLM, tool, retrieval, handoff, guardrail, and approval spans. Framework adapters map source traces to this model. `domain/` and `application/` depend on interfaces rather than SQLAlchemy, vendor SDKs, or LangGraph.

### Analysis and evidence

1. Ingestion writes spans, the trace record, and a durable analysis job in PostgreSQL in one transaction. The job queue is in the same database, so an accepted trace cannot be stranded between a commit and a publish. A job holds IDs only. Business records hold the state, and a periodic task retries the jobs of a worker that stopped.
2. Deterministic checks validate tool arguments, ordering, approvals, and repeated actions. Policy owners write clauses as temporal-logic formulas, and the system compiles each formula to a deterministic automaton at publication. Statistical detectors compare latency, token use, cost, and baseline distributions.
3. Candidate findings retrieve policy clauses, specifications, similar incidents, and evidence summaries through Qdrant with project and version filters. Trajectory paths are derived from the span tree. Source identifiers refer back to authoritative, versioned records.
4. LangGraph coordinates focused trajectory, policy, and efficiency critics only where semantic judgment helps. Each critic receives a bounded, redacted evidence package, has no tools, and returns a structured judgment with evidence IDs and uncertainty.
5. An independent evidence validator checks referenced spans, source versions, span relationships, values, and reproducible metrics. Unsupported judgments remain unconfirmed. RCA synthesis uses validated findings and labels observations, deterministic conclusions, semantic judgments, and hypotheses separately.

Analysis retries must be idempotent. A missing Qdrant projection should surface as an unavailable capability or evaluation `ERROR`, not a fabricated clean result.

### External dependencies

| Dependency | Purpose | Planned failure behavior |
|---|---|---|
| Auth0 | Human OIDC and machine-to-machine credentials | Protected operations unavailable if authentication cannot complete |
| Envoy | API gateway: routing and rate limits for API and OTLP traffic | API entry unavailable; pages still load |
| PostgreSQL | Authoritative traces, metadata, policies, findings, evaluations, job queue | Ingestion, analysis, and core application unavailable; persisted work stays recoverable |
| Blob store | Raw batches and large span fields, over the S3 API | Ingestion unavailable; exporters retry. A check that needs a stored field ends in `ERROR` |
| Qdrant | Embeddings for semantic retrieval | Semantic analysis delayed; deterministic findings and gates continue unless a run requires semantic results |
| ClickHouse (Phase 2) | Span and usage-metric storage, including evaluation traces | Ingestion and analysis of new traces stop; evaluations end in `ERROR` at their deadline; stored gate decisions stay readable |
| LLM provider | Semantic critics and RCA | Deterministic findings remain available; required semantic gates return `ERROR` |

## Getting started

Run `task up` for the whole stack in Docker, or `task dev` for native processes with the datastores in Docker. The current stack is Traefik, backend, frontend, PostgreSQL, and Redis. The target local stack replaces Traefik with Envoy, removes Redis, moves the frontend to Next.js, and adds `worker-analysis`, `worker-semantic`, Qdrant, and SeaweedFS; ClickHouse joins in Phase 2.

A complete setup guide must then specify exact Docker/Compose, Python, and Node versions; Auth0 local configuration or a documented development identity option; secrets injection; database migration; seed data; demo trace import; and a verification request to `/health/ready`. Do not interpret the proposed endpoints in this README as evidence that those commands already work.

## Configuration

The following are **proposed configuration categories**, not implemented environment variables. Publish an exhaustive `.env.example` and secret-handling guide when the services exist.

| Setting category | Example name | Secret | Purpose |
|---|---|---|---|
| Database | `DATABASE_URL` | Yes | PostgreSQL connection |
| Identity | `AUTH0_ISSUER`, `AUTH0_AUDIENCE` | No | Token issuer and audience checks |
| UI session | `AUTH0_CLIENT_SECRET`, `AUTH0_SECRET` | Yes | Next.js sign-in and session encryption |
| Semantic critics | `LLM_API_KEY`, `LLM_MODEL` | API key: yes | Model access and reproducible model selection |
| Vector store | `QDRANT_URL`, `QDRANT_API_KEY` | API key: yes | Qdrant connection |
| Blob store | `S3_ENDPOINT_URL`, `S3_ACCESS_KEY_ID`, `S3_SECRET_ACCESS_KEY` | Keys: yes | S3-compatible object storage |
| Data handling | `TRACE_RETENTION_DAYS`, `REDACTION_POLICY` | Depends on policy | Retention and pre-persistence redaction |

Secrets belong in a secret store or local untracked environment file, never in committed configuration or trace payloads. The deployment must define precedence, validation, rotation, and failure behavior before launch.

## Usage

### Investigate an agent run

1. Instrument a demo customer-support agent to export OTLP spans and identify its project and agent version.
2. Open the trace to inspect the chronological trajectory, tool arguments after redaction, and expected workflow.
3. Follow a finding's evidence IDs to the original span, policy clause, approval requirement, and validator result.
4. Record a reviewer decision without changing the observed trace.

For example, a trace that calls `refund_order(amount=800)` without `request_approval` may show `Outcome: SUCCESS` and `Behavior: FAILED`, supported by the tool span and the applicable version of the refund policy. A missing required step is established from the complete relevant trajectory and its expected-path rule, with trace completeness recorded explicitly.

### Use AgentProof in an agent's CI

The customer CI runs its own agent against a versioned evaluation dataset, submits traces, waits for analysis, and queries a gate. This interface is **proposed**, including route names and CLI commands:

```text
Agent pull request -> run cases -> upload traces -> finalize evaluation
                   -> wait for completion -> compare baseline -> gate result
                   -> PASS: continue | FAIL: block | ERROR: investigate
```

Suggested API contract: `POST /api/v1/evaluations`, trace ingestion associated with the evaluation run, `POST /api/v1/evaluations/{id}/finalize`, and `GET /api/v1/evaluations/{id}/gate`. The client must time out safely, avoid treating pending or `ERROR` as `PASS`, and include dataset, agent version, policy version, evaluator configuration, and baseline identifiers in the result.

## Development

### Layout

```text
agent-proof/
├── backend/            FastAPI, Python 3.13, uv: api, tasks, application,
│                       domain, infrastructure, core
├── frontend/           Next.js (target; Vite today), React 19, Refine, Ant Design, pnpm
├── clients/            Go CI client and GitHub Action (planned)
├── database/           PostgreSQL schema and seed
├── docker/             Compose stack
├── docs/               use case specification, architecture, ADRs
└── Taskfile.yml        task runner
```

The stack is Next.js, React 19, Refine, Ant Design, and React Flow for the web; FastAPI, Pydantic, and SQLAlchemy 2 for the backend; Procrastinate on PostgreSQL for background work; PostgreSQL, Qdrant, an S3-compatible blob store, and ClickHouse (Phase 2); LangGraph for semantic-critic orchestration; Envoy as the API gateway; OpenTelemetry for ingestion; Docker Compose locally and Kubernetes with Helm for a later deployment. Parts of this stack are not in the repository yet. Separate process roles do not require separate domain codebases.

### Standards and local loop

Use Ruff and type checking for Python, ESLint and TypeScript checks for the web app, pytest for backend tests, and Playwright for browser flows. Define commit, review, and branching rules in the repository once it exists. A normal change should pass formatting and type checks, relevant unit tests, integration tests for affected adapters, and a local review of the reference trace.

## Testing

| Tier | Required checks | Intended environment |
|---|---|---|
| Unit | Policy predicates, argument validation, trajectory alignment, metrics, evidence references, gate logic | Pull request CI |
| Contract | OTLP mapping, adapter normalization, stable API/event schemas | Pull request CI |
| Integration | Ingest → persist and defer → worker; PostgreSQL row-level security; Qdrant projections; blob store | Pull request CI with isolated services |
| End to end | Valid refund, omitted approval, wrong tool, invalid amount, retrieval loop, controlled retry, gate outcomes | Staging or test deployment |

Each fixture needs expected finding types and evidence IDs. Test duplicate delivery, worker crashes, missing projections, partial traces, and fail-closed behavior for mandatory gates. A coverage threshold is not specified yet; set one only after the repository and meaningful tests exist.

## Build and deployment

### AgentProof's own CI/CD

| Stage | Proposed check or action | Promotion condition |
|---|---|---|
| Pull request | Ruff, type checks, pytest, frontend lint/build, relevant Playwright tests | Required checks pass |
| Merge to main | Build the backend and frontend images tagged by commit SHA | Images published to a registry |
| Staging | Apply compatible migration once, deploy with Helm, run health and end-to-end smoke tests | Healthy and tested release |
| Production | Promote the same image digests using a controlled release | Explicit release approval in the eventual operating policy |

No migration tool exists yet: the SQL files own the schema until a shared environment exists, and a tool must be added before staging. Use a single migration job before application rollout rather than running migrations concurrently in every API pod. Database changes should be compatible with both old and new application versions across a rolling update. If migration fails, halt rollout. Rollback should restore previous image digests; it must not assume that reversing an arbitrary database migration is safe. A production rollback command and recovery target cannot be verified until the release name, cluster, and deployment process exist.

### Agent customers' CI/CD

AgentProof provides a quality gate inside an existing CI system. The customer executes agent cases in its own environment and sends traces. A gate evaluates the candidate against an explicitly identified baseline and dataset. For example, higher task success must not offset a breached mandatory policy-violation threshold. `FAIL` represents a completed evaluation that violates a configured rule; `ERROR` represents an incomplete or untrustworthy evaluation, including unavailable required analysis.

CI authenticates with a narrowly scoped machine identity, such as `traces:ingest`, `evaluations:run`, and `evaluations:read`, rather than an interactive user account. The planned Go CLI maps `PASS` to exit code 0, `FAIL` to 1, `ERROR` to 2, and pending or timeout to 3. The CLI and its commands are not implemented.

### Environments

Local development is planned with Docker Compose. Staging and production are proposed as Kubernetes/Helm environments; URLs, registry, cluster, approval owner, and rollout timing have not been assigned.

## Observability

Separate **customer agent traces being analyzed** from **AgentProof's own operational telemetry**. Customer OTLP data enters ingestion. Envoy, the frontend, APIs, workers, the job queue, datastore adapters, and LLM calls emit their own logs, metrics, and traces to an operational observability backend.

Track ingestion acceptance and errors, durable-job backlog and age, worker retries, analysis stage latency, index lag, evidence-validator rejection rate, LLM failures, evaluation completeness, and gate results. Planned endpoints are `/health/live` and `/health/ready`; readiness should test only dependencies needed to serve that entrypoint. Dashboard, alert, and runbook locations remain to be established.

## Security

Auth0 is the proposed identity provider. Browser users sign in through Next.js with a server-side session; collectors and CI clients use client credentials. The agent under test and the CI client use separate credentials. Envoy handles API routing and rate limits. The backend validates tokens, checks project membership and ownership of each requested trace or evaluation, and applies a permission table in code. PostgreSQL row-level security is a second tenant check. A scope such as `traces:read` alone never grants access across projects.

Redact credentials and configured sensitive fields before persistence, enforce limits on payload size and access to raw payloads, and audit privileged reads. Limit critic inputs to bounded, filtered evidence and treat retrieved text as untrusted data. Treat trace content as untrusted in the UI. Keep PostgreSQL, Qdrant, the blob store, and ClickHouse on private networks. Section 12.4 of [`ARCHITECTURE.md`](docs/architecture/ARCHITECTURE.md) lists the security findings. TLS termination, encryption at rest, dependency scanning, secret rotation, and vulnerability reporting procedures need implementation and operational review before any real customer data is ingested.

## Compliance and data handling

Agent traces may contain personal data in messages, tool inputs, outputs, or retrieved documents. The design requires project-scoped access, field-level redaction, configurable retention, deletion across PostgreSQL and derived indexes, and auditable raw-payload access. Source and projection deletion must be coordinated so erased records cannot reappear after an index rebuild.

No jurisdictional regime, lawful basis, storage region, processor list, retention duration, or data-protection assessment is established in the provided material. These must be decided for the actual deployment and data before claiming compliance.

## Service levels and support

No production SLO, support hours, on-call rota, or incident channel has been established. The draft specification suggests engineering targets of p95 under 500 ms for ingestion acknowledgement, p95 under 2 seconds for deterministic analysis of a normal trace, and p95 under 2 seconds for the Trace Explorer initial load. These are **unvalidated targets**, not measured guarantees; benchmark the implementation and define alerting and error budgets before production operation.

## Versioning and compatibility

Version public APIs, canonical trace schemas, framework adapters, policies, expected workflows, datasets, evaluator configuration, and gate definitions. A historical finding or gate result should retain its code revision, agent version, complete input/dataset identifier, policy and workflow versions, model identifier, retrieval/index snapshot or source version, analysis configuration, and evidence references.

No release line or support window exists yet. Choose an API compatibility and deprecation policy before the first published integration. Do not suggest that replay is byte-for-byte reproducible when external LLMs or mutable data sources cannot be pinned.

### Artifact lineage

| Layer | Planned identifier | Purpose |
|---|---|---|
| Code and config | Commit SHA, image digest, configuration revision | Identify the running procedure |
| Inputs | Trace IDs, dataset and source-document versions | Identify the evaluated evidence |
| Analysis | Detector, policy, prompt, model, and gate versions | Explain how findings and decisions were produced |
| Results | Evaluation-run ID, finding IDs, evidence IDs | Inspect and compare outcomes |

## Governance

Architectural decisions that change the authoritative store, security boundary, canonical trace model, or gate semantics should be recorded as ADRs under `docs/architecture/adr/`. Project ownership, code review rules, release approval, and incident escalation are open operational decisions; no specific maintainer or approval count is implied here.

## Roadmap

| Phase | Deliverable | Status |
|---|---|---|
| 1. First complete slice | Evaluation and gate first (spec D12): canonical model, OTLP ingestion, policy compiler, detectors, advisory critics, evidence validator, Trace Explorer, comparison, gate, CI client | Planned |
| 2. Production observability | RCA, deletion propagation, ClickHouse span store, online evaluation, sessions, usage dashboards | Planned |
| 3. Production hardening | Additional adapters, operations, scale testing | Planned |

The first complete demonstration is a customer-support refund that succeeds at the task while violating an approval policy. The interface must reveal the missing approval, the exact tool call and applicable policy version, and a gate that rejects the regressed agent version.

## Contributing

Implementation contributions should preserve the authoritative-data boundary, keep domain logic independent of infrastructure SDKs, add evidence-backed tests for new failure classes, and document API or policy changes. Repository-specific instructions and contribution procedures should be added when the source repository is created.

## License

No license has been selected in the supplied project materials. Distribution terms should be documented before publishing the repository.
