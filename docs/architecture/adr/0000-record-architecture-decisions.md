# 1. Record architecture decisions

- **Status:** Accepted
- **Date:** 2026-10-31
- **Deciders:** Nguyễn Vũ
- **Supersedes:** —
- **Superseded by:** —

## Context

This project makes decisions that shape it for years: which datastore, which
integration boundaries, which trade-offs we accept knowingly. Today that reasoning
lives in pull request threads, chat history, and the memory of whoever was in the
room.

All three decay. Threads get archived, chat search fails, people move teams. What
survives is the code, which records *what* we did and never *why* — so a future
change either repeats an experiment we already ran, or removes a constraint that
existed for a reason nobody can now state.

## Decision

We record architecturally significant decisions as ADRs in `docs/architecture/adr/`, one file
per decision, numbered sequentially and written at the time the decision is made.
Records are immutable once accepted: a decision that no longer holds is superseded
by a new record rather than edited.

The criteria for significance, and the process, are in
[README.md](README.md).

## Consequences

**Positive**

- The reasoning behind the system's shape is discoverable from the repository.
- Reviewing a proposal in a pull request surfaces disagreement before
  implementation rather than after.
- New team members can read the history rather than reconstruct it.

**Negative**

- Every significant change costs an extra document and an extra review cycle.
- Judgement is required about what counts as significant; the boundary will be
  argued about.
- An index that nobody maintains rots, and a rotted index is worse than none.

**Neutral**

- Records accumulate and are never deleted. Superseded records stay as history.

## Alternatives considered

**Keep the reasoning in pull request descriptions.** Nothing extra to maintain,
and it is already where the discussion happens. Rejected because it is not
discoverable: finding why a decision was made requires knowing which change made
it, which is exactly what the reader does not know.

**Keep a design document in the team wiki.** Better for long-form design, and
easier to write in. Rejected because it drifts from the code — the wiki is not
reviewed with the change, so it is accurate only until the first thing that
contradicts it merges.

**Record nothing; rely on the code and the team.** Zero cost, and works well
enough while the team is stable. Rejected because it fails precisely when it
matters most: during handover, during an incident, and years later.
