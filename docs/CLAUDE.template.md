<!--
  CLAUDE.md TEMPLATE
  ==================
  Copy to your project root as CLAUDE.md. Claude Code reads it automatically at
  the start of every session in this repository, and it applies to every model
  and every subagent working here.

  Already have a CLAUDE.md? The "Working agreement" section below contains no
  placeholders — append that section alone and leave the rest of yours as it is.

  Same conventions as README.template.md: replace every <PLACEHOLDER>, resolve
  every marker, delete every GUIDANCE comment and this block.

      grep -n '<[A-Z][A-Z0-9_]*>' CLAUDE.md      # must return nothing

  Keep it short. This file is prepended to every conversation, so a rule that is
  obvious ("write tests", "handle errors") costs context and earns nothing.
  Everything here should be something a competent engineer would get *wrong* on
  their first day in this repository.
-->

# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code
in this repository.

## Working agreement

These four rules outrank convenience. They apply to every task in this repository,
including ones the user describes as quick or trivial.

### Never guess

If a fact is not in the repository, in the prompt, or in tool output you have
actually read, you do not know it — ask.

- Do not infer a version, a path, a framework, an API shape, or the user's intent
  from a name, a filename, or a convention seen elsewhere. Read the file, or ask.
- Do not invent commands, flags, environment variables, or config keys. Every
  command you state must exist in this repository's task runner, scripts, or docs.
- Placeholder text (`TODO`, `<PLACEHOLDER>`, an empty stub) is a question to ask,
  not a blank to fill from imagination.

When the unknown does not block the work: do everything that does not depend on
it, state the assumption explicitly in the response, and continue. When proceeding
under a wrong assumption would be unsafe, destructive, or would waste the work
entirely — stop and ask before doing anything.

### Ask before "fixing" code the user supplied

When the user provides a script, a diff, or a file that does not meet the
standards in this document, do not silently rewrite it.

1. Name the specific rule it misses and the line it misses it on.
2. Ask one question per genuine ambiguity — not a questionnaire. If the deviation
   is unambiguous and mechanical, fix it and report it rather than asking.
3. Wait for the answer before restructuring, renaming, reformatting, or changing
   dependencies. Deviations are often deliberate.

Do the work that was asked for. Improvements you noticed but were not asked for
are reported, not applied.

### Always report what was done and changed

Every response that touched anything ends with a plain, factual account:

- **Files changed** — each path, and what changed in it, in one line each.
- **Verified** — the command actually run and its actual result. Not "tests
  should pass"; either the output, or an explicit "not run".
- **Not done** — anything skipped, blocked, or deliberately left out, and why.

Report failures as failures. A test that fails, a step that was skipped, and a
command that was never run are each stated plainly, with the output. Never
describe work as complete on the strength of having written the code.

### Hold the scope

Deliver exactly the requested scope — no silent widening, no silent narrowing. If
part of it turns out to be blocked, finish every other part in full and say
precisely what was left out and why. Scaling the work down is the user's call.

## Commands

<!-- GUIDANCE: Only commands you actually run. The single-test row matters more
     than it looks — without it, a full suite gets run to check one function.
     If a command must run from a subdirectory or needs an activated
     environment, say so here; it is the most common cause of a wasted turn. -->

Run from <WORKING_DIRECTORY, e.g. the repository root>.

| Command | |
|---|---|
| `<SETUP_COMMAND>` | install dependencies and git hooks |
| `<LINT_COMMAND>` | lint and format check |
| `<TEST_COMMAND>` | run the full test suite |
| `<SINGLE_TEST_COMMAND, e.g. pytest tests/test_x.py::test_name>` | run one test |
| `<RUN_COMMAND>` | run the application locally |
| `<BUILD_COMMAND>` | build a release artifact |

<!-- OPTIONAL: keep if a task runner, Makefile, or script index lists the rest. -->
The full list is in <COMMAND_SOURCE, e.g. `task --list`, `make help`, `package.json` scripts>.

## Architecture

<!-- GUIDANCE: The big picture that costs several files to reconstruct — not a
     directory listing, which is discoverable in seconds. Answer: what talks to
     what, where does a request or a record flow, and which module is
     authoritative for which decision. -->

<ARCHITECTURE_SUMMARY, 3-6 sentences: the entry point, the layers a request or
record passes through, and where state lives.>

**Dependency direction.** These are one-way; an import in the reverse direction is
a bug, not a shortcut.

| Layer | May import | Must never import |
|---|---|---|
| <LAYER_1, e.g. api/> | <ALLOWED_IMPORTS> | <FORBIDDEN_IMPORTS> |
| <LAYER_2, e.g. core/> | <ALLOWED_IMPORTS> | <FORBIDDEN_IMPORTS> |

**Single sources of truth.** <AUTHORITATIVE_MODULES, e.g. every caller uses
`src/x.py` for <DECISION>; a second implementation silently diverges.>

<!-- REQUIRED-IF: the project has a database, a schema, or persisted migrations. -->
**Data and migrations.** <MIGRATION_RULE, e.g. schema changes go through
<MIGRATION_COMMAND>; never hand-edit an applied migration.>

<!-- OPTIONAL: keep for a monorepo or any repository with more than one
     independently buildable unit. -->
**Packages.** <PACKAGE_MAP, e.g. which directory is independently versioned,
released, or deployed, and what depends on it.>

## Conventions

<!-- GUIDANCE: Only what the linter cannot catch and a newcomer would get wrong.
     Anything your formatter already enforces does not belong here. -->

- **Style.** <STYLE_RULES, e.g. enforced by <LINT_COMMAND>; the non-obvious part is
  <NON_OBVIOUS_RULE>.>
- **Comments and docstrings.** Keep both as brief and plain as they can be while
  still being understood. The code says *what* it does; a comment carries the *why*
  the code cannot — a business rule, an external constraint, a workaround, a
  deliberate trade-off.
  - Comment only where it makes the code more readable. Prefer a clearer name, a
    smaller function, or a named constant over prose explaining a confusing line.
  - Never restate the code below it. A comment that repeats the code goes stale and
    starts lying the first time the code changes; delete outdated comments and
    commented-out code in the same change that outdated them.
  - Anything that came from outside the code cites its source — the spec, RFC,
    ticket, ADR, or named business rule, as `<REFERENCE_STYLE, e.g. see
    docs/adr/0007-retry-policy.md>`. No magic number or surprising branch without one.
  - Docstrings on <DOCSTRING_SCOPE, e.g. every public module, class, and function>,
    in <DOCSTRING_STYLE, e.g. Google style, enforced by <LINT_COMMAND>>. State what a
    caller needs — behaviour, arguments, return value, what it raises — not how the
    body works.
- **Tests.** <TEST_CONVENTION, e.g. where tests live, what a new one must cover,
  and what must never be reached from a test — network, real data, a live service.>
- **Errors.** <ERROR_CONVENTION, e.g. which exception type or result shape crosses
  a boundary.>
- **Commits.** <COMMIT_CONVENTION, e.g. Conventional Commits; the type drives the
  changelog.>

<!-- REQUIRED-IF: the repository contains generated, vendored, or protected files. -->
## Do not edit

| Path | Change it by |
|---|---|
| <GENERATED_PATH> | <REGENERATE_COMMAND> |
| <LOCKFILE_PATH> | <DEPENDENCY_COMMAND, e.g. never by hand> |
| <VENDORED_PATH> | <UPDATE_PROCESS> |

Secrets live in <SECRET_LOCATION, e.g. `.env`, which is gitignored>. Read
`<EXAMPLE_ENV_FILE, e.g. .env.example>` for the shape; never read, print, or
commit the real values.

## Before calling work done

1. `<LINT_COMMAND>` and `<TEST_COMMAND>` have been **run**, not assumed.
2. The change does what was asked and nothing more.
3. The report from "Always report what was done and changed" is written, with the
   real command output and every skipped item named.

<!-- OPTIONAL: keep if this project has a manual verification step that automation
     does not cover — a UI to look at, an endpoint to curl, a migration to dry-run. -->
4. <MANUAL_VERIFICATION_STEP>

---

<!--
  BEFORE YOU COMMIT THIS FILE
  ===========================
  [ ] `grep -n '<[A-Z][A-Z0-9_]*>' CLAUDE.md` returns nothing.
  [ ] Every REQUIRED-IF and OPTIONAL section is either filled in or deleted
      entirely — heading, marker, and body.
  [ ] Every GUIDANCE comment is deleted.
  [ ] Every command in the Commands table has been run and works, in order, from
      the directory named.
  [ ] The dependency-direction table matches what the code actually does today,
      not what you intend it to do.
  [ ] Nothing here restates a generic engineering practice; every line is
      specific to this repository.
  [ ] No secret, token, internal hostname, or customer name appears anywhere.
  [ ] Delete this checklist.
-->
