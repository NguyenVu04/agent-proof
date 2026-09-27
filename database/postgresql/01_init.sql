-- AgentProof schema (PostgreSQL 18). Applied manually / by docker-entrypoint-initdb.d on first init.
-- Source of truth for canonical business data (README: Architecture, C-01). Qdrant and Neo4j
-- projections must be rebuildable from these rows.
--
-- Conventions
--   * Every tenant-scoped table carries project_id (BR-03: every query is project-filtered).
--   * *_versions, audit, review and gate-decision tables are append-only (FR-02, BR-04, NFR-09):
--     an UPDATE raises; publish a new version instead. DELETE stays possible for retention (UC-13).
--   * Nullable usage/cost columns mean "not reported", never zero (UC-07, UC-11).

BEGIN;

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ---------------------------------------------------------------------------
-- Enums
-- ---------------------------------------------------------------------------
CREATE TYPE member_role        AS ENUM ('ADMIN', 'DEVELOPER', 'POLICY_OWNER', 'REVIEWER', 'EVAL_ENGINEER');
CREATE TYPE audit_outcome      AS ENUM ('ALLOWED', 'DENIED');
CREATE TYPE tool_sensitivity   AS ENUM ('NONE', 'PII', 'FINANCIAL');
CREATE TYPE trace_completeness AS ENUM ('COMPLETE', 'PARTIAL', 'OPEN');
CREATE TYPE processing_status  AS ENUM ('ACCEPTED', 'QUEUED', 'ANALYZING', 'COMPLETED', 'PARTIAL', 'ERROR');
CREATE TYPE outcome_status     AS ENUM ('SUCCESS', 'FAILURE', 'UNKNOWN');
CREATE TYPE behavior_status    AS ENUM ('PENDING', 'PASSED', 'FAILED', 'INCONCLUSIVE');
CREATE TYPE span_kind          AS ENUM ('AGENT', 'LLM', 'TOOL', 'RETRIEVAL', 'HANDOFF', 'GUARDRAIL', 'APPROVAL');
CREATE TYPE span_status        AS ENUM ('UNSET', 'OK', 'ERROR');
CREATE TYPE job_kind           AS ENUM ('ANALYZE_TRACE', 'PROJECT_QDRANT', 'PROJECT_NEO4J', 'EVALUATE', 'DELETE_PROPAGATION');
CREATE TYPE job_status         AS ENUM ('PENDING', 'PUBLISHED', 'RUNNING', 'SUCCEEDED', 'FAILED');
CREATE TYPE run_status         AS ENUM ('PENDING', 'RUNNING', 'COMPLETED', 'PARTIAL', 'ERROR');
CREATE TYPE finding_type       AS ENUM ('WRONG_TOOL', 'INVALID_ARGUMENT', 'ACTION_LOOP', 'RETRIEVAL_LOOP',
                                        'POLICY_VIOLATION', 'NO_PROGRESS', 'INEFFICIENT_TRAJECTORY');
CREATE TYPE finding_status     AS ENUM ('CANDIDATE', 'CONFIRMED', 'UNCONFIRMED', 'INCONCLUSIVE');
CREATE TYPE finding_source     AS ENUM ('DETERMINISTIC', 'STATISTICAL', 'SEMANTIC');
CREATE TYPE severity           AS ENUM ('LOW', 'MEDIUM', 'HIGH', 'CRITICAL');
CREATE TYPE evidence_kind      AS ENUM ('SPAN', 'POLICY_CLAUSE', 'TOOL_VERSION', 'WORKFLOW_VERSION', 'METRIC', 'GRAPH_PATH');
CREATE TYPE review_decision    AS ENUM ('CONFIRMED', 'DISMISSED', 'NEEDS_REVIEW');
CREATE TYPE evaluation_status  AS ENUM ('OPEN', 'FINALIZED', 'COMPLETED', 'ERROR');
CREATE TYPE eval_case_status   AS ENUM ('EXPECTED', 'SUBMITTED', 'ANALYZED', 'MISSING', 'ERROR');
CREATE TYPE gate_result        AS ENUM ('PENDING', 'PASS', 'FAIL', 'ERROR');
CREATE TYPE deletion_status    AS ENUM ('PENDING', 'IN_PROGRESS', 'COMPLETED', 'FAILED');

CREATE FUNCTION forbid_update() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    RAISE EXCEPTION '% is append-only; publish a new version instead', TG_TABLE_NAME
        USING ERRCODE = 'restrict_violation';
END $$;

-- ---------------------------------------------------------------------------
-- Identity and tenancy (UC-01, UC-13)
-- ---------------------------------------------------------------------------
CREATE TABLE users (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    auth0_sub    text NOT NULL UNIQUE,
    email        text,
    display_name text,
    created_at   timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE projects (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    slug                 text NOT NULL UNIQUE,
    name                 text NOT NULL,
    redaction_policy     jsonb NOT NULL DEFAULT '{}',
    trace_retention_days int CHECK (trace_retention_days > 0),  -- NULL = not yet decided
    created_at           timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE project_members (
    project_id uuid NOT NULL REFERENCES projects ON DELETE CASCADE,
    user_id    uuid NOT NULL REFERENCES users ON DELETE CASCADE,
    role       member_role NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (project_id, user_id, role)
);
CREATE INDEX ON project_members (user_id);

-- M2M identities (collector, CI). Scopes never grant cross-project access.
CREATE TABLE machine_clients (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id      uuid NOT NULL REFERENCES projects ON DELETE CASCADE,
    auth0_client_id text NOT NULL,
    name            text NOT NULL,
    scopes          text[] NOT NULL DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now(),
    revoked_at      timestamptz,
    UNIQUE (project_id, auth0_client_id)
);

CREATE TABLE audit_events (
    id              bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    project_id      uuid REFERENCES projects,
    actor_user_id   uuid REFERENCES users,
    actor_client_id uuid REFERENCES machine_clients,
    action          text NOT NULL,           -- e.g. trace.raw.read, finding.review.create
    resource_type   text,
    resource_id     uuid,
    outcome         audit_outcome NOT NULL,
    details         jsonb NOT NULL DEFAULT '{}',  -- never erased content (UC-13)
    created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON audit_events (project_id, created_at DESC);

-- ---------------------------------------------------------------------------
-- Versioned evaluation context (UC-02)
-- ---------------------------------------------------------------------------
CREATE TABLE agents (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id  uuid NOT NULL REFERENCES projects ON DELETE CASCADE,
    name        text NOT NULL,
    description text,
    created_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (project_id, name)
);

CREATE TABLE agent_versions (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id      uuid NOT NULL REFERENCES projects ON DELETE CASCADE,
    agent_id        uuid NOT NULL REFERENCES agents ON DELETE CASCADE,
    version         text NOT NULL,
    code_revision   text,
    prompt_revision text,
    model_id        text,
    metadata        jsonb NOT NULL DEFAULT '{}',
    created_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (agent_id, version)
);

CREATE TABLE tools (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id uuid NOT NULL REFERENCES projects ON DELETE CASCADE,
    name       text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (project_id, name)
);

CREATE TABLE tool_versions (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id        uuid NOT NULL REFERENCES projects ON DELETE CASCADE,
    tool_id           uuid NOT NULL REFERENCES tools ON DELETE CASCADE,
    version           int NOT NULL CHECK (version > 0),
    description       text,
    input_schema      jsonb NOT NULL,             -- JSON Schema for argument validation (UC-05)
    side_effecting    boolean NOT NULL DEFAULT false,
    sensitivity       tool_sensitivity NOT NULL DEFAULT 'NONE',
    permitted_retries int NOT NULL DEFAULT 0 CHECK (permitted_retries >= 0),  -- UC-07
    created_at        timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tool_id, version)
);

CREATE TABLE policies (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id uuid NOT NULL REFERENCES projects ON DELETE CASCADE,
    code       text NOT NULL,                     -- e.g. REFUND-004
    title      text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (project_id, code)
);

CREATE TABLE policy_versions (
    id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id   uuid NOT NULL REFERENCES projects ON DELETE CASCADE,
    policy_id    uuid NOT NULL REFERENCES policies ON DELETE CASCADE,
    version      int NOT NULL CHECK (version > 0),
    content      text NOT NULL,
    published_by uuid REFERENCES users,
    published_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (policy_id, version)
);

CREATE TABLE policy_clauses (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id        uuid NOT NULL REFERENCES projects ON DELETE CASCADE,
    policy_version_id uuid NOT NULL REFERENCES policy_versions ON DELETE CASCADE,
    clause_key        text NOT NULL,
    text              text NOT NULL,
    applies_when      jsonb,   -- machine predicate; NULL = natural-language only (semantic critic)
    requires          jsonb,   -- e.g. {"prior_steps": ["lookup_policy", "request_approval"]}
    UNIQUE (policy_version_id, clause_key)
);

CREATE TABLE workflows (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id uuid NOT NULL REFERENCES projects ON DELETE CASCADE,
    name       text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (project_id, name)
);

CREATE TABLE workflow_versions (
    id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id  uuid NOT NULL REFERENCES projects ON DELETE CASCADE,
    workflow_id uuid NOT NULL REFERENCES workflows ON DELETE CASCADE,
    version     int NOT NULL CHECK (version > 0),
    definition  jsonb NOT NULL,  -- steps (REQUIRED/OPTIONAL/CONDITIONAL), transitions, forbidden
    created_at  timestamptz NOT NULL DEFAULT now(),
    UNIQUE (workflow_id, version)
);

-- A pinned bundle of policy/workflow/tool versions that traces and evaluations reference.
CREATE TABLE evaluation_contexts (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id          uuid NOT NULL REFERENCES projects ON DELETE CASCADE,
    name                text NOT NULL,
    workflow_version_id uuid REFERENCES workflow_versions,
    created_at          timestamptz NOT NULL DEFAULT now(),
    UNIQUE (project_id, name)
);

CREATE TABLE evaluation_context_policies (
    context_id        uuid NOT NULL REFERENCES evaluation_contexts ON DELETE CASCADE,
    policy_version_id uuid NOT NULL REFERENCES policy_versions,
    PRIMARY KEY (context_id, policy_version_id)
);

CREATE TABLE evaluation_context_tools (
    context_id      uuid NOT NULL REFERENCES evaluation_contexts ON DELETE CASCADE,
    tool_version_id uuid NOT NULL REFERENCES tool_versions,
    PRIMARY KEY (context_id, tool_version_id)
);

-- ---------------------------------------------------------------------------
-- Traces (UC-03, UC-04)
-- ---------------------------------------------------------------------------
CREATE TABLE traces (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id           uuid NOT NULL REFERENCES projects ON DELETE CASCADE,
    agent_version_id     uuid NOT NULL REFERENCES agent_versions,
    context_id           uuid REFERENCES evaluation_contexts,
    external_trace_id    text NOT NULL,           -- OTel trace id
    idempotency_key      text NOT NULL,
    source_format        text NOT NULL DEFAULT 'otlp',
    completeness         trace_completeness NOT NULL DEFAULT 'OPEN',
    processing_status    processing_status NOT NULL DEFAULT 'ACCEPTED',
    outcome_status       outcome_status NOT NULL DEFAULT 'UNKNOWN',   -- BR-05: independent of
    behavior_status      behavior_status NOT NULL DEFAULT 'PENDING',  -- behavioral result
    started_at           timestamptz,
    ended_at             timestamptz,
    total_input_tokens   int,
    total_output_tokens  int,
    total_cost_usd       numeric(12, 6),
    warnings             jsonb NOT NULL DEFAULT '[]',   -- normalizer warnings, e.g. missing parent
    retention_expires_at timestamptz,
    deleted_at           timestamptz,
    created_at           timestamptz NOT NULL DEFAULT now(),
    UNIQUE (project_id, idempotency_key),
    UNIQUE (project_id, external_trace_id)
);
CREATE INDEX ON traces (project_id, created_at DESC);
CREATE INDEX ON traces (agent_version_id);

-- Pre-redaction payload kept apart so access can be restricted and audited (NFR-07).
CREATE TABLE trace_raw_payloads (
    trace_id   uuid PRIMARY KEY REFERENCES traces ON DELETE CASCADE,
    project_id uuid NOT NULL REFERENCES projects ON DELETE CASCADE,
    payload    jsonb NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE spans (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id       uuid NOT NULL REFERENCES projects ON DELETE CASCADE,
    trace_id         uuid NOT NULL REFERENCES traces ON DELETE CASCADE,
    parent_span_id   uuid REFERENCES spans ON DELETE CASCADE,
    external_span_id text NOT NULL,
    seq              int NOT NULL,                -- chronological order within the trace
    kind             span_kind NOT NULL,
    name             text NOT NULL,
    tool_version_id  uuid REFERENCES tool_versions,
    status           span_status NOT NULL DEFAULT 'UNSET',
    started_at       timestamptz,
    ended_at         timestamptz,
    input            jsonb,                       -- redacted
    output           jsonb,                       -- redacted
    attributes       jsonb NOT NULL DEFAULT '{}',
    input_tokens     int,
    output_tokens    int,
    cost_usd         numeric(12, 6),
    result_hash      text,                        -- retrieval-loop detection (UC-07)
    UNIQUE (trace_id, external_span_id),
    UNIQUE (trace_id, seq)
);
CREATE INDEX ON spans (parent_span_id);

-- ---------------------------------------------------------------------------
-- Durable work: job records double as the transactional outbox (UC-03, C-03)
-- ---------------------------------------------------------------------------
CREATE TABLE jobs (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id      uuid REFERENCES projects ON DELETE CASCADE,
    kind            job_kind NOT NULL,
    idempotency_key text NOT NULL UNIQUE,
    payload         jsonb NOT NULL DEFAULT '{}',
    status          job_status NOT NULL DEFAULT 'PENDING',
    attempts        int NOT NULL DEFAULT 0,
    max_attempts    int NOT NULL DEFAULT 5,
    available_at    timestamptz NOT NULL DEFAULT now(),
    published_at    timestamptz,     -- NULL = not yet handed to Redis; recovery sweep republishes
    last_error      text,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON jobs (status, available_at);

-- ---------------------------------------------------------------------------
-- Analysis, findings and evidence (UC-05 .. UC-08)
-- ---------------------------------------------------------------------------
-- Re-analysis is a new run, never an edit of an old one (BR-04).
CREATE TABLE analysis_runs (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id       uuid NOT NULL REFERENCES projects ON DELETE CASCADE,
    trace_id         uuid NOT NULL REFERENCES traces ON DELETE CASCADE,
    job_id           uuid REFERENCES jobs ON DELETE SET NULL,
    analyzer_version text NOT NULL,
    config           jsonb NOT NULL DEFAULT '{}',
    status           run_status NOT NULL DEFAULT 'PENDING',
    error            jsonb,
    started_at       timestamptz,
    finished_at      timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON analysis_runs (trace_id);

CREATE TABLE findings (
    id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id       uuid NOT NULL REFERENCES projects ON DELETE CASCADE,
    trace_id         uuid NOT NULL REFERENCES traces ON DELETE CASCADE,
    analysis_run_id  uuid NOT NULL REFERENCES analysis_runs ON DELETE CASCADE,
    type             finding_type NOT NULL,
    status           finding_status NOT NULL DEFAULT 'CANDIDATE',
    severity         severity NOT NULL,
    source           finding_source NOT NULL,
    title            text NOT NULL,
    explanation      text,
    confidence       numeric(4, 3) CHECK (confidence BETWEEN 0 AND 1),  -- semantic only
    detector_version text NOT NULL,
    dedupe_key       text NOT NULL,        -- idempotent retries don't duplicate findings (NFR-05)
    details          jsonb NOT NULL DEFAULT '{}',  -- e.g. trajectory diff
    validated_at     timestamptz,
    created_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (analysis_run_id, dedupe_key)
);
CREATE INDEX ON findings (trace_id);
CREATE INDEX ON findings (project_id, type, status);

CREATE TABLE finding_evidence (
    id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id          uuid NOT NULL REFERENCES projects ON DELETE CASCADE,
    finding_id          uuid NOT NULL REFERENCES findings ON DELETE CASCADE,
    kind                evidence_kind NOT NULL,
    span_id             uuid REFERENCES spans ON DELETE CASCADE,
    policy_clause_id    uuid REFERENCES policy_clauses,
    tool_version_id     uuid REFERENCES tool_versions,
    workflow_version_id uuid REFERENCES workflow_versions,
    value               jsonb,             -- quoted values / metric results
    note                text,
    CHECK (num_nonnulls(span_id, policy_clause_id, tool_version_id, workflow_version_id, value) >= 1)
);
CREATE INDEX ON finding_evidence (finding_id);

CREATE TABLE evidence_validations (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id        uuid NOT NULL REFERENCES projects ON DELETE CASCADE,
    finding_id        uuid NOT NULL REFERENCES findings ON DELETE CASCADE,
    validator_version text NOT NULL,
    passed            boolean NOT NULL,
    rejection_reasons jsonb NOT NULL DEFAULT '[]',
    created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON evidence_validations (finding_id);

-- RCA keeps observations, rule-derived conclusions, semantic judgments and hypotheses apart (FR-08).
CREATE TABLE rca_reports (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id      uuid NOT NULL REFERENCES projects ON DELETE CASCADE,
    trace_id        uuid NOT NULL REFERENCES traces ON DELETE CASCADE,
    analysis_run_id uuid NOT NULL REFERENCES analysis_runs ON DELETE CASCADE,
    model_id        text,
    observations    jsonb NOT NULL DEFAULT '[]',
    conclusions     jsonb NOT NULL DEFAULT '[]',
    judgments       jsonb NOT NULL DEFAULT '[]',
    hypotheses      jsonb NOT NULL DEFAULT '[]',
    recommendations jsonb NOT NULL DEFAULT '[]',
    created_at      timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
-- Human review (UC-09). Annotations never overwrite findings.
-- Each new review must supersede the latest one: the unique constraints make a
-- review against an obsolete version fail instead of silently replacing another.
-- ---------------------------------------------------------------------------
CREATE TABLE finding_reviews (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id           uuid NOT NULL REFERENCES projects ON DELETE CASCADE,
    finding_id           uuid NOT NULL REFERENCES findings ON DELETE CASCADE,
    reviewer_id          uuid NOT NULL REFERENCES users,
    decision             review_decision NOT NULL,
    rationale            text,
    supersedes_review_id uuid UNIQUE REFERENCES finding_reviews ON DELETE CASCADE,
    created_at           timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX finding_reviews_one_root ON finding_reviews (finding_id)
    WHERE supersedes_review_id IS NULL;

-- ---------------------------------------------------------------------------
-- Datasets and evaluations (UC-10 .. UC-12)
-- ---------------------------------------------------------------------------
CREATE TABLE datasets (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id uuid NOT NULL REFERENCES projects ON DELETE CASCADE,
    name       text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (project_id, name)
);

CREATE TABLE dataset_versions (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id uuid NOT NULL REFERENCES projects ON DELETE CASCADE,
    dataset_id uuid NOT NULL REFERENCES datasets ON DELETE CASCADE,
    version    int NOT NULL CHECK (version > 0),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (dataset_id, version)
);

CREATE TABLE dataset_cases (
    id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id         uuid NOT NULL REFERENCES projects ON DELETE CASCADE,
    dataset_version_id uuid NOT NULL REFERENCES dataset_versions ON DELETE CASCADE,
    case_key           text NOT NULL,
    input              jsonb NOT NULL,
    expected           jsonb NOT NULL DEFAULT '{}',
    UNIQUE (dataset_version_id, case_key)
);

CREATE TABLE evaluation_runs (
    id                   uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id           uuid NOT NULL REFERENCES projects ON DELETE CASCADE,
    agent_version_id     uuid NOT NULL REFERENCES agent_versions,
    dataset_version_id   uuid NOT NULL REFERENCES dataset_versions,
    context_id           uuid NOT NULL REFERENCES evaluation_contexts,
    evaluator_version    text NOT NULL,
    evaluator_config     jsonb NOT NULL DEFAULT '{}',
    code_revision        text,                    -- customer commit SHA under test
    idempotency_key      text NOT NULL,
    status               evaluation_status NOT NULL DEFAULT 'OPEN',
    deadline_at          timestamptz,
    finalized_at         timestamptz,   -- submission complete; case set frozen
    completed_at         timestamptz,   -- all required analysis terminal
    error                jsonb,
    created_by_client_id uuid REFERENCES machine_clients,
    created_at           timestamptz NOT NULL DEFAULT now(),
    UNIQUE (project_id, idempotency_key)
);

-- Frozen expected case set -> submitted trace.
CREATE TABLE evaluation_cases (
    evaluation_run_id uuid NOT NULL REFERENCES evaluation_runs ON DELETE CASCADE,
    dataset_case_id   uuid NOT NULL REFERENCES dataset_cases,
    trace_id          uuid REFERENCES traces ON DELETE SET NULL,
    status            eval_case_status NOT NULL DEFAULT 'EXPECTED',
    outcome_status    outcome_status,   -- as reported by the customer; never inferred
    PRIMARY KEY (evaluation_run_id, dataset_case_id)
);
CREATE INDEX ON evaluation_cases (trace_id);

CREATE TABLE evaluation_metrics (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id        uuid NOT NULL REFERENCES projects ON DELETE CASCADE,
    evaluation_run_id uuid NOT NULL REFERENCES evaluation_runs ON DELETE CASCADE,
    metric_key        text NOT NULL,
    metric_version    text NOT NULL,
    numerator         numeric,
    denominator       numeric,
    value             numeric,          -- NULL when not computable
    missing_count     int NOT NULL DEFAULT 0,
    excluded_count    int NOT NULL DEFAULT 0,
    UNIQUE (evaluation_run_id, metric_key)
);

CREATE TABLE comparisons (
    id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id              uuid NOT NULL REFERENCES projects ON DELETE CASCADE,
    candidate_run_id        uuid NOT NULL REFERENCES evaluation_runs,
    baseline_run_id         uuid NOT NULL REFERENCES evaluation_runs,
    compatible              boolean NOT NULL,
    incompatibility_reasons jsonb NOT NULL DEFAULT '[]',
    zero_baseline_rule      text NOT NULL,
    created_at              timestamptz NOT NULL DEFAULT now(),
    CHECK (candidate_run_id <> baseline_run_id)
);

CREATE TABLE comparison_metrics (
    comparison_id   uuid NOT NULL REFERENCES comparisons ON DELETE CASCADE,
    metric_key      text NOT NULL,
    baseline_value  numeric,
    candidate_value numeric,
    absolute_delta  numeric,
    relative_delta  numeric,            -- NULL when the baseline is 0 or data is missing
    PRIMARY KEY (comparison_id, metric_key)
);

CREATE TABLE gates (
    id         uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id uuid NOT NULL REFERENCES projects ON DELETE CASCADE,
    name       text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (project_id, name)
);

CREATE TABLE gate_versions (
    id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id    uuid NOT NULL REFERENCES projects ON DELETE CASCADE,
    gate_id       uuid NOT NULL REFERENCES gates ON DELETE CASCADE,
    version       int NOT NULL CHECK (version > 0),
    rules         jsonb NOT NULL,     -- [{metric, op, threshold, mandatory}]
    review_policy jsonb NOT NULL DEFAULT '{}',
    created_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (gate_id, version)
);

CREATE TABLE gate_decisions (
    id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id        uuid NOT NULL REFERENCES projects ON DELETE CASCADE,
    evaluation_run_id uuid NOT NULL REFERENCES evaluation_runs ON DELETE CASCADE,
    comparison_id     uuid REFERENCES comparisons,
    gate_version_id   uuid NOT NULL REFERENCES gate_versions,
    result            gate_result NOT NULL,
    breaches          jsonb NOT NULL DEFAULT '[]',
    diagnostics       jsonb NOT NULL DEFAULT '{}',
    decided_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ON gate_decisions (evaluation_run_id, decided_at DESC);

-- ---------------------------------------------------------------------------
-- Governance (UC-13). Propagation to Qdrant/Neo4j runs as DELETE_PROPAGATION jobs.
-- ---------------------------------------------------------------------------
CREATE TABLE deletion_requests (
    id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    project_id      uuid NOT NULL REFERENCES projects ON DELETE CASCADE,
    requested_by    uuid REFERENCES users,
    target_trace_id uuid,              -- no FK: the trace is what gets erased
    older_than      timestamptz,       -- retention sweep
    reason          text NOT NULL,
    status          deletion_status NOT NULL DEFAULT 'PENDING',
    created_at      timestamptz NOT NULL DEFAULT now(),
    completed_at    timestamptz,
    CHECK (num_nonnulls(target_trace_id, older_than) = 1)
);

-- ---------------------------------------------------------------------------
-- Append-only enforcement
-- ---------------------------------------------------------------------------
DO $$
DECLARE t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'agent_versions', 'tool_versions', 'policy_versions', 'policy_clauses',
        'workflow_versions', 'evaluation_contexts', 'dataset_versions', 'dataset_cases',
        'gate_versions', 'gate_decisions', 'evidence_validations', 'finding_reviews',
        'audit_events'
    ] LOOP
        EXECUTE format(
            'CREATE TRIGGER %1$s_append_only BEFORE UPDATE ON %1$I FOR EACH ROW EXECUTE FUNCTION forbid_update()',
            t);
    END LOOP;
END $$;

COMMIT;
