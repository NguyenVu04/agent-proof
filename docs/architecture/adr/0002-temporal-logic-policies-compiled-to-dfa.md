# 3. Write policies in temporal logic and compile them to DFAs

- **Status:** Accepted
- **Date:** 2026-10-31
- **Deciders:** Nguyễn Vũ
- **Supersedes:** —
- **Superseded by:** —

## Context

A gate must give the same result for the same pinned inputs (NFR-06), and it must not claim an absence that it cannot prove (BR-02). Policy checks are the main differentiator of AgentProof, and they set the meaning of a gate result.

The first format, a JSON predicate schema (D2), cannot link data between steps. An approval for order A would satisfy a refund of order B, so a gate could pass wrongly. Plain LTLf has the same gap, because it has no data.

The documents read for the architecture show no comparable system that uses automata for policy checks. AgentProof has no reference design for this part.

## Decision

Policy owners write each clause in LTLf with one `forall` variable. The system parses the formula, checks its types against the pinned tool versions, and compiles it to a DFA at publication. The compiler stores the DFA with the immutable clause version. It rejects a formula above the limits. The parser limits nesting depth, and the compile step has a time limit.

The runner reads the stored DFA during analysis, with one run for each value of the variable. A hidden value gives `INCONCLUSIVE`. Workflows stay as a JSON graph and lower to formulas.

## Consequences

**Positive**

- The stored DFA pins the behaviour of each clause version, so a later compiler cannot change an old result.
- A run is a table lookup, with no model and no search.
- A formula that is too large fails at publication, not during analysis.
- The `forall` variable finds an approval for the wrong order.

**Negative**

- This is the largest part of the domain code. AgentProof owns a parser, a type checker and a compiler.
- States can grow very fast, so limits apply. The limits of 12 atoms and 1024 states are proposals with no test.
- Policy owners must learn temporal logic. No user test exists, and this is the largest product risk of the decision.
- A formula outside the known patterns gives `VIOLATED` with no `missing` or `wrong-order` kind.

**Neutral**

- The compiler and the runner must agree on a JSON format, and `compiler_version` records it.
- A clause with no formula goes to the policy critic, and its findings are advisory.

## Alternatives considered

**Direct evaluation of the finished trace.** A trace is complete at analysis, so a table per subformula and position is enough, and three-valued logic handles a hidden value. This option removes the compiler, the state limits and the stored format. Its cost is that behaviour depends on the code version, not on a stored table. Claude Code recommended it during the review of 2026-10-31. The requester kept the DFA.

**Formula progression at run time.** It needs less code. It lost because run time grows with the formula, and a large formula fails only during analysis.

**`ltlf2dfa` with MONA.** An existing translator. It lost because it needs the MONA binary, and the three-valued result and the witness stay own work.

**Keep the JSON predicate schema.** It is easy to author and validate. It lost because it cannot link data between steps, so a gate could pass wrongly.

See `ARCHITECTURE.md` AD-10, AD-24, AD-25 and AD-27, and specification D14.
