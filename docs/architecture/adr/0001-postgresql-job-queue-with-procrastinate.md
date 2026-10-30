# 2. Use PostgreSQL with Procrastinate as the job queue

- **Status:** Accepted
- **Date:** 2026-10-31
- **Deciders:** Nguyễn Vũ
- **Supersedes:** —
- **Superseded by:** —

## Context

AgentProof must not lose accepted work, and it must not repeat a finding (NFR-05). The first design used Celery on Redis, with a `jobs` table as a transactional outbox. In that design, PostgreSQL held the truth, and Redis delivered only a pointer.

This design had a high cost for what it gave:

- One more store, and a `scheduler` role that must have one instance.
- Three time limits that must keep a fixed order.
- A Redis client below version 6.5, because of a `kombu` constraint.
- A bridge from synchronous tasks to async code.

Heavy stacks in comparable systems followed measured load. Langfuse added its queue after it processed tens of thousands of events per minute. AgentProof has no load target yet, because NFR-11 is open and C-05 keeps the deployment local. Jobs follow traces, not spans, so the job rate is much lower than the span rate.

## Decision

We use PostgreSQL as the job queue, through Procrastinate. A job commits in the same transaction as its anchor record, on the same connection. We remove Redis, Celery, the `scheduler` role, the outbox and the `jobs` table.

Business records anchor each job, for example one `analysis_runs` row. Task arguments hold IDs only. Periodic tasks replace the timed sweeps, and one of them retries stalled jobs. The backend moves from asyncpg to psycopg 3, because the Procrastinate documents name psycopg and do not name asyncpg.

## Consequences

**Positive**

- A trace and its job cannot separate, so no sweep has to close a gap after a commit.
- The first slice has one store and one process role fewer.
- Tasks are coroutines, so the bridge to async code goes away.
- Several workers can run, because the database starts each periodic task once per period.

**Negative**

- PostgreSQL carries the queue load, and it is already the critical store. The job table needs autovacuum tuning.
- Job throughput is lower than with a dedicated broker. Nobody measured it for AgentProof.
- Procrastinate does not retry stalled jobs by itself, so that periodic task is own code.
- Retry state lives in the schema of a library, and each upgrade can need a SQL migration.
- Workers need a direct PostgreSQL connection. `LISTEN` may not work through PgBouncer in transaction mode. This statement comes from general knowledge.

**Neutral**

- The Procrastinate tables have no row-level security, so they must never hold content.
- A task can still run twice, so each write stays idempotent.

## Alternatives considered

**Own claim loop on the `jobs` table.** `FOR UPDATE SKIP LOCKED` and `LISTEN/NOTIFY` need no new dependency, and the design already had the claim rule. Claude Code recommended this option. The requester chose Procrastinate, which gives retries and periodic tasks with no own code.

**Keep Celery on Redis.** It is a known tool with high throughput and separate queues. It lost because the `jobs` table already held the state, so Celery only delivered a pointer at the cost of one more store and one more role.

**Keep `jobs` as a business record beside Procrastinate.** The claim rules and states would stay independent of the library schema. It lost because two writers would hold the same state.

See `ARCHITECTURE.md` AD-03, AD-14, AD-23 and AD-30, and specification D19.
