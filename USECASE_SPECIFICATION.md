# AgentProof — Use Case Specification

> **Document status:** Draft product specification, 27 September 2026. The use cases describe intended behavior; they do not assert that an implementation or API already exists. This document follows the AgentProof project specification and README, including Auth0, Traefik Hub, PostgreSQL, Qdrant, Neo4j, Redis, and semantic critics orchestrated with LangGraph. Fine-tuning and execution of arbitrary customer agent code are outside the initial scope.

## 1. Purpose and scope

AgentProof evaluates how an AI agent carried out a task. It collects an execution trace, checks tool use and policy constraints, compares the observed trajectory with an expected workflow, and explains confirmed failures through inspectable evidence. Teams can also evaluate a candidate agent version against a baseline and use the result as a release gate.

An **outcome** describes whether the agent completed the user's task. A **behavioral result** describes whether its observed actions met the configured requirements. Both must remain visible; a successful refund can still violate an approval policy.

The initial reference domain is a customer-support agent. Other domains use the same trace and evidence model but require their own policies, tool specifications, and evaluation data.

### Actors

| Actor | Role |
|---|---|
| Agent developer | Integrates telemetry, investigates failures, compares agent versions. |
| Project administrator | Manages project membership and versioned evaluation artifacts. |
| Policy owner | Defines operational rules and expected workflows. |
| Reviewer | Accepts, dismisses, or requests more evidence for a finding. |
| Evaluation engineer | Curates test cases, baselines, and regression gates. |
| Customer agent / OTel Collector | Exports execution telemetry using a scoped machine identity. |
| CI system | Submits evaluation traces and consumes a gate decision. |
| Analysis worker | Executes asynchronous checks and records results; it is an internal actor. |

### Shared vocabulary and states

| Term | Meaning |
|---|---|
| Project | Authorization boundary for agents, traces, knowledge, policies, and evaluations. |
| Trace | One agent execution with parent-child spans and an explicit completeness state. |
| Policy / workflow version | Immutable evaluation input identifying the rules applicable to a run. |
| Candidate finding | Suspected failure awaiting sufficient evidence or validation. |
| Confirmed finding | Validated failure with resolvable, authorized evidence references. |
| Review decision | Human assessment attached to, rather than overwriting, a finding. |
| Evaluation run | Versioned set of trace-based results for a specific candidate, dataset, and evaluator configuration. |
| Baseline | Pinned comparison run or approved agent version evaluated under compatible conditions. |
| Gate result | `PASS`, `FAIL`, or `ERROR`; pending work has a separate nonterminal state. |

`ERROR` means the evaluation could not produce a trustworthy decision. It is not an agent behavior failure and must never be converted to `PASS` merely because no confirmed findings were produced.

## 2. Use case catalog

| ID | Use case | Primary actor | Initial scope |
|---|---|---|---|
| UC-01 | Enter a project and authorize access | Human user / CI client | Foundation |
| UC-02 | Register an agent and versioned evaluation context | Project administrator | Foundation |
| UC-03 | Ingest and normalize an agent trace | Agent / OTel Collector | MVP |
| UC-04 | Inspect a trace and its execution trajectory | Agent developer | MVP |
| UC-05 | Detect tool misuse and invalid arguments | Analysis worker | MVP |
| UC-06 | Verify policies and expected trajectories | Policy owner / analysis worker | MVP |
| UC-07 | Detect loops and inefficient behavior | Analysis worker | MVP, with later semantic expansion |
| UC-08 | Validate semantic judgments and generate an RCA | Analysis worker / reviewer | MVP |
| UC-09 | Review a finding and its evidence | Reviewer | MVP |
| UC-10 | Evaluate an agent version on an external test run | Evaluation engineer / CI | MVP |
| UC-11 | Compare a candidate with a baseline | Evaluation engineer | MVP |
| UC-12 | Enforce a CI regression gate | CI system | MVP |
| UC-13 | Govern sensitive trace data and projections | Project administrator | MVP controls; operations mature later |

## 3. Detailed use cases

### UC-01 — Enter a project and authorize access

**Goal:** Give a person or machine only the project resources and operations it is entitled to use.

**Primary actors:** Human user, CI client, collector. **Supporting actor:** Project administrator.

**Preconditions:** A project exists; the identity is registered and mapped to that project. A human can complete OIDC sign-in; a machine can obtain a client-credentials token.

**Trigger:** An actor requests a protected API operation.

**Main flow:**

1. Auth0 issues an access token for the intended API audience with appropriate scopes.
2. Traefik Hub validates token and coarse route or scope requirements.
3. FastAPI resolves the actor and project context and checks operation-specific authorization.
4. For resource access, FastAPI verifies the resource belongs to the project and the actor is allowed to access that project.
5. The system performs the operation and records an audit event where required.

**Alternatives and failures:** An expired or invalid token is rejected. A valid token with insufficient scope or incorrect project membership is denied. A request for a trace in another project is denied even if the token includes `traces:read`. Missing identity infrastructure prevents protected access; cached authorization must not silently grant new permissions.

**Postcondition:** No cross-project resource data is disclosed; an authorized operation may proceed.

**Acceptance criteria:** Human and machine identities have distinct flows; project ownership is checked at the application boundary; M2M clients can be scoped to ingestion or evaluation without `projects:admin`; denials are auditable without leaking sensitive resource contents.

### UC-02 — Register an agent and versioned evaluation context

**Goal:** Define the agent, tools, policies, and expected workflows needed to interpret its runs.

**Primary actors:** Project administrator and policy owner.

**Preconditions:** The actors have project administration or policy-writing permissions.

**Trigger:** The team onboards an agent or publishes a change to its behavior contract.

**Main flow:**

1. The administrator creates an agent identity and registers an agent version, including code or prompt revision metadata where available.
2. The policy owner publishes versioned policy clauses and identifies the side effects and sensitivity of each tool.
3. The owner defines required, optional, conditional, and forbidden workflow transitions.
4. The system validates references between policies, tools, and workflow steps; it records immutable versions in PostgreSQL.
5. Background jobs update scoped Qdrant indexes and Neo4j relationship projections; the source version remains available to evaluations independently of index state.

**Alternatives and failures:** An invalid tool reference or contradictory workflow is rejected with a specific validation error. Replacing a published rule produces a new version. A failed index update leaves the authoritative version intact but marks retrieval or graph-dependent analysis unavailable until rebuilt.

**Postcondition:** New evaluations can pin exact agent, policy, workflow, and tool-specification versions; historical runs keep their original versions.

**Acceptance criteria:** A past finding resolves its original policy clause after a policy update; a semantic search applies project and version filters; changing an artifact does not silently rewrite prior decisions.

### UC-03 — Ingest and normalize an agent trace

**Goal:** Turn an agent's telemetry into a project-scoped canonical execution record without performing expensive analysis in the request path.

**Primary actor:** Customer agent or OTel Collector.

**Preconditions:** The caller has a scoped ingestion identity and an existing project and agent version. A redaction configuration is active.

**Trigger:** The caller submits OTLP-compatible spans or a supported framework-specific trace.

**Main flow:**

1. The gateway and ingestion entrypoint authenticate the caller, enforce project boundaries and payload limits, and validate trace identifiers and structure.
2. Redaction runs before sensitive fields are persisted. The adapter maps source spans to canonical agent, LLM, tool, retrieval, handoff, guardrail, and approval types.
3. The normalizer reconstructs parent-child and chronological relationships, records warnings, and marks the trace `COMPLETE`, `PARTIAL`, or `OPEN` according to an explicit completion contract.
4. PostgreSQL stores the canonical trace, source metadata needed for diagnostics, and a durable analysis-job record using a stable idempotency key.
5. The ingestion API acknowledges acceptance. Job publication to Redis is retried or recovered by an outbox/sweep if the queue is temporarily unavailable.

**Alternatives and failures:** Duplicate delivery returns the existing trace or an idempotent acknowledgement without duplicate findings. Malformed payloads are rejected with actionable errors. A missing parent span is recorded as incomplete structure. A database failure prevents successful acceptance. A persisted but temporarily unqueued trace remains recoverable and is never reported as fully analyzed.

**Postcondition:** An accepted trace is retrievable with a visible processing state and durable path to analysis.

**Acceptance criteria:** Replaying the same delivery does not multiply traces; a worker crash or queue outage cannot silently lose accepted work; redacted values are absent from normal persisted views; trace completeness is available to downstream detectors.

### UC-04 — Inspect a trace and its execution trajectory

**Goal:** Let a developer understand what happened and reach the evidence for any finding.

**Primary actor:** Agent developer.

**Preconditions:** A trace exists in the developer's authorized project.

**Trigger:** The developer selects a trace from the project view.

**Main flow:**

1. The UI shows outcome, behavioral and analysis states separately, plus the agent and policy versions.
2. The developer switches between chronological and hierarchical spans and filters tool, LLM, retrieval, handoff, and approval events.
3. The UI displays redacted arguments, statuses, timing, token use, and available costs.
4. The developer selects a finding, follows its evidence IDs to the relevant spans and policy or workflow version, and opens the expected-versus-actual path view.

**Alternatives and failures:** A partial trace is marked clearly; an incomplete run must not imply that an unseen approval was absent. If the graph projection is unavailable, the canonical span timeline and findings can still be displayed, with the graph view marked unavailable. Raw payload access requires additional authorization and audit logging.

**Postcondition:** The user can reconstruct the reported behavior from source records and identify any unavailable analysis components.

**Acceptance criteria:** Each visible confirmed finding links to resolvable evidence in the same authorized project; the UI preserves ordering and parent-child distinctions; sensitive values remain masked in standard views.

### UC-05 — Detect tool misuse and invalid arguments

**Goal:** Identify a wrong tool choice or an invalid invocation using the strongest available evidence.

**Primary actor:** Analysis worker. **Beneficiary:** Agent developer.

**Preconditions:** Tool specifications and relevant domain state are versioned; the trace includes the required tool call data.

**Trigger:** UC-03 queues a trace for analysis.

**Main flow:**

1. The worker checks tool names, schema versions, argument types, permitted ranges, and domain constraints using deterministic validators.
2. It distinguishes a schema violation from an argument that is structurally valid but inconsistent with observed state, such as refunding more than the order value.
3. If tool choice requires interpreting the task intent, a candidate `WRONG_TOOL` finding is passed to a bounded semantic critic with the task, tool specifications, and relevant spans.
4. The evidence validator resolves cited records and verifies values before a finding is confirmed.

**Alternatives and failures:** A missing specification or hidden required argument makes the assessment `INCONCLUSIVE`; it is not a clean pass. A failed tool call can still have invalid arguments, but execution failure and misuse are separate observations. If a side-effecting tool was already executed, AgentProof reports the event and its risk; the initial product does not retroactively prevent execution.

**Postcondition:** The run has validated findings, unconfirmed candidates, or an explicit insufficient-evidence state.

**Acceptance criteria:** `INVALID_ARGUMENT` and `WRONG_TOOL` are distinct; findings cite the tool span and specification or domain value; the report identifies whether validation preceded or followed the action.

### UC-06 — Verify policies and expected trajectories

**Goal:** Determine whether observed actions satisfy applicable business rules and workflow prerequisites.

**Primary actors:** Policy owner and analysis worker.

**Preconditions:** The run is associated with an immutable policy/workflow version and enough trace data to decide the relevant constraints.

**Trigger:** A trace contains a governed action or an evaluation requests workflow conformance.

**Main flow:**

1. The worker identifies applicable policy conditions from tool arguments and prior observed state.
2. It evaluates deterministic requirements first: required steps, order, conditional branches, forbidden transitions, and approval before side effects.
3. The trajectory comparer emits a machine-readable difference: missing, unexpected, repeated, wrong-order, forbidden, or incomplete step.
4. For ambiguous natural-language clauses, semantic retrieval obtains the exact policy version and a policy critic proposes a judgment.
5. The validator checks the source clause, relevant spans, event order, and trace completeness before confirming a `POLICY_VIOLATION` or related finding.

**Reference scenario:** For `refund_order(order_id=1024, amount=800)`, policy `REFUND-004` version 3 requires policy lookup and human approval before the refund. If a complete trace shows `find_order → refund_order`, the system reports the missing prerequisites while preserving `Outcome: SUCCESS` if the refund actually completed.

**Alternatives and failures:** An optional branch does not fail merely because it was skipped. If policy applicability is undecidable or the trace is partial at the approval boundary, return `INCONCLUSIVE` or an analysis error according to the evaluation contract; do not assert absence from incomplete evidence. Contradictory policies are reported as a configuration error.

**Postcondition:** Applicable checks and path differences are recorded with source versions and evidence.

**Acceptance criteria:** Same inputs and rule versions produce the same deterministic result; missing and wrong-order steps are distinguished; a confirmed violation names the exact clause and ordered action spans; partial traces cannot create a false missing-approval claim.

### UC-07 — Detect loops and inefficient behavior

**Goal:** Find repeated or unnecessary work and quantify its observed cost where the data permits.

**Primary actor:** Analysis worker.

**Preconditions:** The trace contains ordered actions; retrieval-result hashes or summaries and usage metrics are available for semantic or cost analysis.

**Trigger:** The worker analyzes an accepted trace or an evaluation aggregates runs.

**Main flow:**

1. Deterministic checks detect repeated identical calls and repeated subsequences.
2. Retrieval analysis measures overlap or semantic similarity between consecutive results and checks for new evidence or state changes.
3. The worker excludes retries that a tool policy explicitly permits and labels uncertain efficiency judgments as candidates.
4. It reports observed extra calls, tokens, and latency; avoidable cost is an estimate only when its counterfactual assumptions are stated.

**Alternatives and failures:** Similar queries can be justified if results or task state change materially. Missing retrieval outputs prevent a confident `RETRIEVAL_LOOP` decision. A Qdrant outage does not erase deterministic repetition findings but can make semantic progress assessment unavailable.

**Postcondition:** Findings such as `ACTION_LOOP`, `RETRIEVAL_LOOP`, `NO_PROGRESS`, or `INEFFICIENT_TRAJECTORY` carry relevant span sequences and method/configuration versions.

**Acceptance criteria:** Exact loops need no LLM; permitted retries do not trigger false positives; a semantic-loop finding includes the compared evidence or summaries and configured decision threshold; estimated impact is labeled separately from observed usage.

### UC-08 — Validate semantic judgments and generate an RCA

**Goal:** Explain confirmed failures without promoting unsupported model claims to facts.

**Primary actor:** Analysis worker. **Beneficiary:** Reviewer.

**Preconditions:** Candidate findings exist; retrievable evidence has project, version, and access metadata.

**Trigger:** Deterministic or statistical analysis submits a candidate requiring contextual judgment or explanation.

**Main flow:**

1. A retriever builds a bounded evidence package from authorized Qdrant candidates, Neo4j relationships, and authoritative PostgreSQL records.
2. LangGraph routes the package to applicable trajectory, policy, or efficiency critics; each returns a structured decision, reason, uncertainty, and evidence IDs.
3. The evidence validator checks IDs, source versions, quoted values, graph relationships, metric calculations, and redaction constraints.
4. A valid judgment can become a confirmed finding. Unsupported claims remain unconfirmed and are visible as insufficient evidence or analysis diagnostics.
5. The RCA synthesizer combines validated findings with relevant relationships and clearly separates observed facts, rule-derived conclusions, semantic judgments, and hypotheses. Recommendations point to a concrete action or control.

**Alternatives and failures:** An LLM response without evidence IDs cannot confirm a finding. A source record missing from a projection is verified against the authoritative store; unrecoverable discrepancies become analysis errors. Prompt-injection text in retrieved material is treated as data, not as an instruction to the critic. An unavailable LLM does not invalidate already confirmed deterministic findings.

**Postcondition:** The report has traceable assertions, or it clearly states that a causal claim cannot be established.

**Acceptance criteria:** Every confirmed semantic finding has validated evidence IDs; an RCA cannot claim that a planner failed to read a policy as an observed fact unless the trace supports it; validators record rejection reasons; models do not have unrestricted datastore access.

### UC-09 — Review a finding and its evidence

**Goal:** Allow a human to confirm, dismiss, or request follow-up on an analysis result.

**Primary actor:** Reviewer.

**Preconditions:** A finding or candidate exists in an authorized project.

**Trigger:** The reviewer opens a finding from the trace or evaluation UI.

**Main flow:**

1. The reviewer sees the failure type, severity, evaluator version, confidence if applicable, evidence, source policy, trace completeness, and system analysis state.
2. The reviewer follows evidence references and records `CONFIRMED`, `DISMISSED`, or `NEEDS_REVIEW`, with an optional rationale.
3. The system stores a separate, timestamped annotation with actor identity and preserves the machine-produced finding and evidence.
4. Evaluation reports distinguish automated findings from reviewer decisions; if review changes gate eligibility, the gate is recomputed with the review-policy version recorded.

**Alternatives and failures:** An unauthorized reviewer cannot see or annotate a finding. An annotation submitted against an obsolete version prompts a conflict resolution rather than silently replacing another review.

**Postcondition:** The original result and human judgment remain independently inspectable.

**Acceptance criteria:** Review actions are auditable; dismissing one finding does not delete its trace or evidence; exported evaluation data includes the review state and policy governing its effect on gates.

### UC-10 — Evaluate an agent version on an external test run

**Goal:** Produce an evaluation run from customer-executed agent cases without running arbitrary customer code inside AgentProof.

**Primary actors:** Evaluation engineer and CI system.

**Preconditions:** A versioned dataset and evaluation configuration exist; the client can authenticate and execute its own agent.

**Trigger:** A developer proposes a code, prompt, tool, model, or workflow change.

**Main flow:**

1. The client creates an evaluation run pinned to project, agent candidate version, dataset version, policy/workflow versions, and evaluator configuration.
2. Customer CI executes each case and submits resulting traces with case IDs and idempotency keys.
3. The client signals that submission is complete. The system freezes the expected case set and waits for ingestion and all required analysis jobs to reach terminal states.
4. The evaluator aggregates outcomes, finding rates, policy violations, trajectory conformance, latency, tokens, and cost, preserving denominators and missing-data counts.
5. The system publishes a versioned report and exposes a machine-readable result when the run is complete.

**Alternatives and failures:** Missing cases, duplicate IDs, incomplete traces, or required critic failures prevent an apparently complete evaluation. A deadline can mark the run `ERROR` with the missing work recorded; it does not imply that the candidate passed. Retrying a trace upload or finalize request is idempotent. A case outcome that the customer did not provide is not inferred from a polished final answer.

**Postcondition:** The run is completed with reproducible inputs or has an explicit error and diagnostic record.

**Acceptance criteria:** The system never executes the customer's production agent; an evaluation cannot be finalized while required analyses are pending; each metric exposes numerator, denominator, exclusions, and configuration version.

### UC-11 — Compare a candidate with a baseline

**Goal:** Determine whether a proposed agent version regresses in behavior, quality, latency, or cost.

**Primary actor:** Evaluation engineer.

**Preconditions:** Candidate and baseline evaluations are complete and have compatible dataset, policy, metric definitions, and evaluator settings; differences are explicitly documented where comparison is allowed.

**Trigger:** The engineer selects a candidate and an approved baseline, or UC-12 requests comparison.

**Main flow:**

1. The system validates compatibility and records the comparison inputs.
2. It presents side-by-side outcome and trajectory metrics, absolute changes, relative changes where the denominator is nonzero, and uncertainty or sample-size context where appropriate.
3. The engineer drills into cases contributing to a changed metric and opens their trace-level findings.
4. The comparison becomes a pinned input to a gate decision.

**Alternatives and failures:** Incompatible or missing dataset versions produce a comparison error rather than a misleading percentage. A baseline metric of zero requires a defined handling rule instead of division by zero. Missing token or cost data remains visible as missing data, not a zero-valued improvement.

**Postcondition:** A reproducible comparison links each aggregate to source evaluation runs and contributing cases.

**Acceptance criteria:** Critical policy failures are not hidden inside a composite score; absolute and relative deltas are distinct; a comparison can be traced to its exact baseline and candidate versions.

### UC-12 — Enforce a CI regression gate

**Goal:** Provide a reliable decision for an existing CI system before an agent version is promoted.

**Primary actor:** CI system. **Supporting actor:** Evaluation engineer.

**Preconditions:** A versioned gate definition exists; the candidate and baseline meet UC-10 and UC-11 requirements. CI has narrowly scoped M2M permissions.

**Trigger:** The CI workflow requests a gate result for the completed evaluation.

**Main flow:**

1. The system evaluates each configured requirement against pinned metrics, findings, and baseline changes.
2. Mandatory safety requirements are evaluated independently of improvements in unrelated measures.
3. It returns `PASS` if all requirements are verifiably satisfied, or `FAIL` with each breached requirement and its observed value if the complete trustworthy evaluation violates at least one requirement.
4. CI continues promotion only for `PASS`; it presents the report and stops promotion for `FAIL`.

**Alternatives and failures:** A pending evaluation returns a nonterminal state. Unavailable required analyses, missing cases, stale projections needed for a requirement, incompatible baseline, or internal failure produce `ERROR` and diagnostics. CI must block automatic promotion for `ERROR` as well as `FAIL`; a manual override, if ever supported, is a separate authorized and audited process.

**Postcondition:** The decision and its exact gate, input, metric, and evaluator versions are stored and inspectable.

**Acceptance criteria:** Gate outcomes are stable for the same pinned inputs; CI distinguishes `PASS`, `FAIL`, `ERROR`, and pending; policy-violation limits cannot be offset by improved task success; a response includes a concise machine-readable explanation.

### UC-13 — Govern sensitive trace data and derived projections

**Goal:** Keep telemetry accessible only to authorized people and honor data retention or deletion policy across all derived stores.

**Primary actor:** Project administrator. **Supporting actor:** Operations worker.

**Preconditions:** Data is associated with a project and has a declared classification, retention policy, and redaction settings.

**Trigger:** A privileged read, scheduled retention expiry, or authorized deletion request occurs.

**Main flow:**

1. The system enforces project and role checks before disclosing trace fields and records privileged raw-payload access.
2. At expiry or authorized erasure, PostgreSQL marks the source records and manages deletion according to the chosen policy.
3. A durable deletion/reprojection job removes or invalidates corresponding Qdrant vectors, Neo4j nodes/edges, and any relevant caches.
4. The system verifies the projection state and keeps an audit record that does not itself re-expose erased content.

**Alternatives and failures:** A projection outage leaves the request pending with a retryable status and blocks reindexing of deleted source material. A legal or operational hold, if implemented, must be a separately authorized and documented rule. A request for data outside the administrator's project is denied.

**Postcondition:** The system reaches a verifiable deletion state, or explicitly exposes incomplete propagation for follow-up.

**Acceptance criteria:** Erased data does not reappear after index rebuilds; access to raw payloads is recorded; error paths do not leak sensitive fields; each project can identify its configured retention and redaction policy.

## 4. Cross-use-case rules

1. **Evidence first:** A confirmed finding references resolvable source IDs and the validation result. Model confidence alone never establishes a fact.
2. **Completeness-aware reasoning:** Absence claims such as “approval was omitted” require a sufficiently complete trace for the relevant action interval.
3. **Tenant boundaries:** Every API query and vector/graph traversal is constrained by project identity and source version; metadata filters are checked again at the authoritative record.
4. **Version pinning:** A run records agent, dataset, policy, workflow, evaluator, and gate versions. Re-evaluation is a new result, not a silent edit to history.
5. **Independent outcome and behavior:** A task can succeed while behavior fails, or fail without a policy violation.
6. **Failure semantics:** Operational failure and insufficient evidence produce explicit incomplete or `ERROR` states. They are never counted as successful agent behavior.
7. **Asynchronous visibility:** The UI and API expose accepted, queued, analyzing, completed, partial, and error states rather than implying immediate semantic analysis after ingestion.
8. **Human review:** Reviewer annotations preserve original detector outputs and must follow a defined rule before affecting a release gate.

## 5. Reference end-to-end scenario

**Policy:** `REFUND-004` version 3 requires a policy lookup and human approval before a refund above $500.

| Step | Action | Expected observable result |
|---|---|---|
| 1 | Register `support-agent` version 1.5 and applicable policy/workflow versions | Immutable evaluation context |
| 2 | Customer CI runs case `refund-1024` with requested amount $800 | Trace with case ID and agent version |
| 3 | Agent calls `find_order(1024)` then `refund_order(1024, 800)` | Complete trace; no approval span in the relevant interval |
| 4 | Agent returns “Your refund has been completed” | Outcome may be `SUCCESS` if the tool result confirms it |
| 5 | AgentProof evaluates ordering and prerequisites | `POLICY_VIOLATION` with tool span and `REFUND-004` v3 evidence |
| 6 | Evidence validator verifies source values and completeness | Confirmed finding; RCA may recommend a tool-boundary approval precondition |
| 7 | Version comparison and mandatory gate run | `FAIL` if the configured violation limit is breached; CI stops promotion |

If the approval interval is missing from telemetry, step 5 is **inconclusive** rather than a confirmed violation. If semantic analysis required by the gate cannot complete, step 7 is `ERROR` and CI still stops automatic promotion.

## 6. Release acceptance for the first complete slice

- A customer-support agent exports a trace containing the reference tools `find_customer`, `find_order`, `lookup_policy`, `request_approval`, `refund_order`, and `send_email` where applicable.
- Ingestion accepts and normalizes traces idempotently, records completeness, and recovers accepted work after a worker or queue interruption.
- The five initial failure classes `WRONG_TOOL`, `INVALID_ARGUMENT`, `ACTION_LOOP`, `RETRIEVAL_LOOP`, and `POLICY_VIOLATION` have controlled positive and negative scenarios.
- Every confirmed finding leads to validated, project-authorized evidence and the exact policy or tool-specification version.
- The Trace Explorer shows a successful outcome with a failed behavioral result for the high-value refund case.
- Two agent versions can be evaluated on the same pinned dataset; comparison exposes missing data and incompatible inputs.
- A mandatory regression gate returns `FAIL` for the policy regression, while incomplete or unavailable required analysis returns `ERROR`.
- A reviewer can annotate findings without mutating canonical trace or machine-generated evidence.
- The complete demonstration is exercised through the local deployment with backend integration and browser end-to-end tests.
