-- pg_plan_override: Dynamic per-query planner GUC overrides
-- Schema is auto-created by control file (schema = pg_plan_override)

-- Rules table
CREATE TABLE plan_override.override_rules (
    id            SERIAL PRIMARY KEY,
    query_id      BIGINT,
    query_pattern TEXT,
    description   TEXT,
    gucs          JSONB NOT NULL,
    enabled       BOOLEAN DEFAULT true,
    priority      INTEGER DEFAULT 0,
    created_at    TIMESTAMPTZ DEFAULT now()
);

-- Must have at least one matching method
ALTER TABLE plan_override.override_rules
    ADD CONSTRAINT chk_match_method
    CHECK (query_id IS NOT NULL OR query_pattern IS NOT NULL);

-- Index for fast queryId lookup
CREATE INDEX idx_override_rules_query_id
    ON plan_override.override_rules (query_id) WHERE enabled;

-- Helper: add rule by queryId
CREATE FUNCTION plan_override.add_by_query_id(
    p_query_id BIGINT, p_gucs JSONB, p_description TEXT DEFAULT NULL
) RETURNS INTEGER AS $$
    INSERT INTO plan_override.override_rules (query_id, gucs, description)
    VALUES (p_query_id, p_gucs, p_description)
    RETURNING id;
$$ LANGUAGE SQL;

-- Helper: add rule by LIKE pattern
CREATE FUNCTION plan_override.add_by_pattern(
    p_pattern TEXT, p_gucs JSONB, p_description TEXT DEFAULT NULL
) RETURNS INTEGER AS $$
    INSERT INTO plan_override.override_rules (query_pattern, gucs, description)
    VALUES (p_pattern, p_gucs, p_description)
    RETURNING id;
$$ LANGUAGE SQL;

-- Force cache refresh (C function)
CREATE FUNCTION plan_override.refresh_cache() RETURNS VOID
    AS 'MODULE_PATHNAME', 'pg_plan_override_refresh_cache' LANGUAGE C STRICT;
