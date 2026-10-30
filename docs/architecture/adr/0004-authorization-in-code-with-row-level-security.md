# 5. Keep authorization in code, with row-level security as a second lock

- **Status:** Accepted
- **Date:** 2026-10-31
- **Deciders:** Nguyễn Vũ
- **Supersedes:** —
- **Superseded by:** —

## Context

NFR-04 allows zero unauthorized disclosures or writes. BR-03 requires a project filter on each query. One forgotten filter would leak the data of another tenant, and only a test could find it.

Authorization has two parts: who may do an action, and which rows a query may touch. The roles are few and fixed (`ADMIN`, `DEVELOPER`, `POLICY_OWNER`, `REVIEWER`, `EVAL_ENGINEER`). No requirement needs attribute conditions or rules that customers write. A rule file inside the image needs a deploy for each change, as code does.

## Decision

Each protected request passes three checks: the token, the project grants, and a permission table in `core/authz.py`. The table maps each action to the roles that may do it. An action that is not in the table is denied. For a machine client, the permission is the intersection of the token scopes and `machine_clients.scopes`.

Row-level security is a second lock on every tenant table. Each transaction sets `app.project_id`, and a missing setting returns no rows. No process role holds `BYPASSRLS`. Sweeps call narrow `SECURITY DEFINER` functions with a fixed `search_path`.

## Consequences

**Positive**

- A forgotten filter returns no rows, not the rows of another tenant.
- The permission table adds no dependency and no network call.
- One table-driven test covers each action and each role.
- A worker that parses untrusted data holds no credential that bypasses row-level security.

**Negative**

- Each transaction needs a project context, and the schema needs more roles, policies and functions.
- A change of permission needs a deploy.
- Conditions on attributes need more code.
- Row-level security protects only PostgreSQL. Qdrant, the blob store and ClickHouse depend on their adapters.

**Neutral**

- Foreign-key checks bypass row-level security. Tenant IDs are random UUIDs, which limits that risk, and cross-project tests stay mandatory.
- Repositories still filter by project. Row-level security is the second lock, not the first.

## Alternatives considered

**External policy engine in the process.** Rules become data, separate from logic, and the engine denies by default. It lost because the rule file ships in the image, so a change still needs a deploy, and the Python binding had no vendor support.

**Auth0 RBAC.** Permissions travel in the token. It lost because per-project roles are hard to express, and old tokens keep their rights until they expire.

**Policy engine as a service.** It has separate tools and a rule language. It lost because it adds one service and one network call, and an outage denies every operation.

**Application filters only, with row-level security later.** This costs less work now. It lost because the requester wants a second lock from the start.

**One schema or database per project.** This gives the strongest isolation. It lost because migrations multiply, and seed and tooling change.

See `ARCHITECTURE.md` AD-08, AD-15 and section 6.14.
