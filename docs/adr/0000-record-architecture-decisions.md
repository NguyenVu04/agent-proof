<!--
  This file is both the record template and, as written, a real first ADR.

  To adopt the practice: copy this file into your project as
  docs/adr/0000-record-architecture-decisions.md, set the date, and it is done —
  the decision it records is the decision to keep ADRs at all.

  To write a new record: copy this file to NNNN-short-title-in-kebab-case.md and
  replace the content. Keep the five headings; they are the whole discipline.
  Delete this comment block in either case.
-->

# 1. Record architecture decisions

- **Status:** Accepted
- **Date:** <YYYY-MM-DD>
- **Deciders:** <WHO_DECIDED>
- **Supersedes:** —
- **Superseded by:** —

## Context

<!-- GUIDANCE: The situation that forces a decision — constraints, pressures, and
     what is currently true. Write it so a reader who was not there understands
     why this was hard. State facts, not the conclusion. -->

This project makes decisions that shape it for years: which datastore, which
integration boundaries, which trade-offs we accept knowingly. Today that reasoning
lives in pull request threads, chat history, and the memory of whoever was in the
room.

All three decay. Threads get archived, chat search fails, people move teams. What
survives is the code, which records *what* we did and never *why* — so a future
change either repeats an experiment we already ran, or removes a constraint that
existed for a reason nobody can now state.

## Decision

<!-- GUIDANCE: One paragraph, active voice, present tense: "We do X." Not "we
     should" or "we will consider". -->

We record architecturally significant decisions as ADRs in `docs/adr/`, one file
per decision, numbered sequentially and written at the time the decision is made.
Records are immutable once accepted: a decision that no longer holds is superseded
by a new record rather than edited.

The criteria for significance, and the process, are in
[README.md](README.md).

## Consequences

<!-- GUIDANCE: Both directions. A record that lists only benefits is advocacy, not
     a decision record — and it is the costs that a future reader needs, because
     they are what changed by the time they are reading. -->

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

<!-- GUIDANCE: What else was on the table, and the specific reason it lost. "We
     considered X" with no reason is not useful; the reason is the entire value,
     because it is what a future reader re-evaluates when circumstances change. -->

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
