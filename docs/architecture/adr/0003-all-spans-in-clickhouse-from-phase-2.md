# 4. Store all spans in ClickHouse from Phase 2

- **Status:** Accepted
- **Date:** 2026-10-31
- **Deciders:** Nguyễn Vũ
- **Supersedes:** —
- **Superseded by:** —

## Context

Phase 2 adds production traces, online evaluation and usage dashboards. Langfuse and LangSmith both keep spans in ClickHouse, and Langfuse reports PostgreSQL IOPS exhaustion on trace volume. Spans stay in PostgreSQL in the first slice.

An earlier README said that gates do not depend on ClickHouse. Detectors read spans, so that statement and an all-spans move cannot both hold. ClickHouse also gives weaker read-after-write guarantees than PostgreSQL. A detector that sees a part of a trace could claim that a step is absent, which breaks BR-02.

NFR-11 has no target yet, so no measurement shows when PostgreSQL stops being enough.

## Decision

From Phase 2, all spans go to ClickHouse, including evaluation traces. PostgreSQL keeps the control plane and every decision record. `SpanStore` hides the change from the use cases. Before analysis, the worker compares the span count in ClickHouse with `traces.span_count` in PostgreSQL. If ClickHouse has fewer spans, the job retries, and it then ends in `ERROR`.

## Consequences

**Positive**

- One span store, so dashboards and detectors read one place.
- Evaluation and production traces use the same read path.
- The design matches two comparable systems, so their lessons apply.

**Negative**

- From Phase 2, a ClickHouse outage stops new analysis. Runs end in `ERROR` at their deadline, and CI stops promotions.
- ClickHouse is a cost from the start of Phase 2, before any measurement shows a need.
- A span that a collector resends in a new batch gives a false `ERROR`. That result is safe, but it can block a good run.
- A span migration is still open.

**Neutral**

- Row-level security does not apply to ClickHouse, so the adapter adds the project filter.
- Stored gate decisions stay in PostgreSQL, so they stay readable in an outage.

## Alternatives considered

**Keep evaluation spans in PostgreSQL, and send production spans to ClickHouse.** Gates would need only PostgreSQL, and the span-count check would go away. Claude Code recommended this option twice. The cost is two span stores, and dashboards must read both. The requester chose one span store.

**Add ClickHouse only after a measurement shows a need.** This delays the cost until NFR-11 has a target. Claude Code recommended this option during the review of 2026-10-31. The requester kept this decision and D18 as they are.

See `ARCHITECTURE.md` AD-05 and section 7.15, and specification D18.
