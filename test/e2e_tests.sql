-- ============================================================
-- pg_plan_override — end-to-end test suite (11 tests)
-- ============================================================

\pset pager off

-- Setup: create extension and test data
CREATE EXTENSION pg_plan_override;

CREATE TABLE test_orders (
    id          SERIAL PRIMARY KEY,
    customer_id INTEGER NOT NULL,
    amount      NUMERIC(10,2) NOT NULL,
    created_at  TIMESTAMPTZ DEFAULT now()
);

INSERT INTO test_orders (customer_id, amount)
SELECT
    (random() * 100)::int,
    (random() * 1000)::numeric(10,2)
FROM generate_series(1, 10000);

CREATE INDEX idx_test_orders_customer ON test_orders (customer_id);
CREATE INDEX idx_test_orders_amount   ON test_orders (amount);

ANALYZE test_orders;

-- ============================================================
-- Test 1: Extension loads — override_rules table exists
-- ============================================================
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.tables
        WHERE table_schema = 'plan_override'
          AND table_name   = 'override_rules'
    ) THEN
        RAISE EXCEPTION 'Test 1 FAILED: override_rules table not found';
    END IF;
    RAISE NOTICE 'Test 1 PASSED: extension loaded, override_rules table exists';
END;
$$;

-- ============================================================
-- Test 2: Pattern match disables seq scan
-- ============================================================
DO $$
DECLARE
    rec         RECORD;
    plan_output TEXT := '';
BEGIN
    PERFORM plan_override.add_by_pattern(
        '%test_orders%',
        '{"enable_seqscan": "off"}'::jsonb,
        'Test 2: disable seqscan'
    );
    PERFORM plan_override.refresh_cache();

    FOR rec IN EXECUTE 'EXPLAIN SELECT * FROM test_orders WHERE customer_id = 42' LOOP
        plan_output := plan_output || rec."QUERY PLAN" || E'\n';
    END LOOP;

    IF plan_output LIKE '%Seq Scan%' THEN
        RAISE EXCEPTION 'Test 2 FAILED: expected no Seq Scan, got: %', plan_output;
    END IF;
    RAISE NOTICE 'Test 2 PASSED: pattern match disabled seq scan';
END;
$$;

-- ============================================================
-- Test 3: GUC restoration after planning
-- ============================================================
DO $$
DECLARE
    val TEXT;
BEGIN
    val := current_setting('enable_seqscan');
    IF val <> 'on' THEN
        RAISE EXCEPTION 'Test 3 FAILED: enable_seqscan not restored, got: %', val;
    END IF;
    RAISE NOTICE 'Test 3 PASSED: GUC restored to original value';
END;
$$;

-- Cleanup: remove all rules before next group
DELETE FROM plan_override.override_rules;
SELECT plan_override.refresh_cache();

-- ============================================================
-- Test 4: Cache refresh picks up directly-inserted rule
-- ============================================================
DO $$
DECLARE
    rec         RECORD;
    plan_output TEXT := '';
BEGIN
    -- Insert rule directly (bypass helper functions)
    INSERT INTO plan_override.override_rules
        (query_pattern, gucs, enabled, priority)
    VALUES
        ('%cache_refresh_check%',
         '{"enable_indexscan": "off", "enable_bitmapscan": "off"}'::jsonb,
         true, 0);

    PERFORM plan_override.refresh_cache();

    FOR rec IN EXECUTE
        'EXPLAIN SELECT /* cache_refresh_check */ * FROM test_orders WHERE customer_id = 42'
    LOOP
        plan_output := plan_output || rec."QUERY PLAN" || E'\n';
    END LOOP;

    IF plan_output NOT LIKE '%Seq Scan%' THEN
        RAISE EXCEPTION 'Test 4 FAILED: expected Seq Scan (index scans disabled), got: %', plan_output;
    END IF;
    RAISE NOTICE 'Test 4 PASSED: cache refresh applied directly-inserted rule';
END;
$$;

-- ============================================================
-- Test 5: Disabled rule is ignored
-- ============================================================
DO $$
DECLARE
    rec         RECORD;
    plan_output TEXT := '';
BEGIN
    UPDATE plan_override.override_rules
       SET enabled = false
     WHERE query_pattern = '%cache_refresh_check%';
    PERFORM plan_override.refresh_cache();

    FOR rec IN EXECUTE
        'EXPLAIN SELECT /* cache_refresh_check */ * FROM test_orders WHERE customer_id = 42'
    LOOP
        plan_output := plan_output || rec."QUERY PLAN" || E'\n';
    END LOOP;

    -- With the rule disabled, planner should choose Index Scan (not forced Seq Scan)
    IF plan_output LIKE '%Seq Scan%' THEN
        RAISE EXCEPTION 'Test 5 FAILED: disabled rule still forcing Seq Scan: %', plan_output;
    END IF;
    RAISE NOTICE 'Test 5 PASSED: disabled rule correctly ignored';
END;
$$;

-- Cleanup
DELETE FROM plan_override.override_rules;
SELECT plan_override.refresh_cache();

-- ============================================================
-- Test 6: No-match passthrough
-- ============================================================
DO $$
DECLARE
    rec         RECORD;
    plan_output TEXT := '';
BEGIN
    FOR rec IN EXECUTE 'EXPLAIN SELECT 1' LOOP
        plan_output := plan_output || rec."QUERY PLAN" || E'\n';
    END LOOP;

    IF plan_output NOT LIKE '%Result%' THEN
        RAISE EXCEPTION 'Test 6 FAILED: expected Result node for SELECT 1, got: %', plan_output;
    END IF;
    RAISE NOTICE 'Test 6 PASSED: no-match passthrough works correctly';
END;
$$;

-- ============================================================
-- Test 7: Debug GUC — toggle on/off, trigger matching query
-- ============================================================
DO $$
BEGIN
    PERFORM plan_override.add_by_pattern(
        '%debug_guc_test%',
        '{"enable_seqscan": "off"}'::jsonb,
        'Test 7: debug GUC'
    );
    PERFORM plan_override.refresh_cache();

    -- Enable debug logging
    SET pg_plan_override.debug = on;

    -- Trigger a matching query (debug LOG emitted in server logs)
    EXECUTE 'SELECT /* debug_guc_test */ count(*) FROM test_orders WHERE customer_id = 1';

    -- Disable debug logging
    SET pg_plan_override.debug = off;

    RAISE NOTICE 'Test 7 PASSED: debug GUC toggled on/off without error (check server logs for LOG messages)';
END;
$$;

-- Cleanup
DELETE FROM plan_override.override_rules;
SELECT plan_override.refresh_cache();

-- ============================================================
-- Test 8: Master switch disables all overrides
-- ============================================================
DO $$
DECLARE
    rec         RECORD;
    plan_output TEXT := '';
BEGIN
    PERFORM plan_override.add_by_pattern(
        '%master_switch_test%',
        '{"enable_seqscan": "off"}'::jsonb,
        'Test 8: master switch'
    );
    PERFORM plan_override.refresh_cache();

    -- Disable the master switch
    SET pg_plan_override.enabled = off;

    -- Full table scan query — naturally prefers Seq Scan
    FOR rec IN EXECUTE 'EXPLAIN SELECT /* master_switch_test */ * FROM test_orders' LOOP
        plan_output := plan_output || rec."QUERY PLAN" || E'\n';
    END LOOP;

    -- Override should NOT apply, so Seq Scan should appear
    IF plan_output NOT LIKE '%Seq Scan%' THEN
        RAISE EXCEPTION 'Test 8 FAILED: master switch off but override still applied, got: %', plan_output;
    END IF;

    -- Re-enable for subsequent tests
    SET pg_plan_override.enabled = on;

    RAISE NOTICE 'Test 8 PASSED: master switch correctly disables all overrides';
END;
$$;

-- Cleanup
DELETE FROM plan_override.override_rules;
SELECT plan_override.refresh_cache();

-- ============================================================
-- Test 9: Priority ordering — highest priority rule wins
-- ============================================================
DO $$
DECLARE
    rec         RECORD;
    plan_output TEXT := '';
BEGIN
    -- Low priority (1): disable seqscan → would force Index Scan
    INSERT INTO plan_override.override_rules
        (query_pattern, gucs, enabled, priority)
    VALUES
        ('%priority_ordering_test%',
         '{"enable_seqscan": "off"}'::jsonb,
         true, 1);

    -- High priority (100): disable index+bitmap scans → forces Seq Scan
    INSERT INTO plan_override.override_rules
        (query_pattern, gucs, enabled, priority)
    VALUES
        ('%priority_ordering_test%',
         '{"enable_indexscan": "off", "enable_bitmapscan": "off"}'::jsonb,
         true, 100);

    PERFORM plan_override.refresh_cache();

    FOR rec IN EXECUTE
        'EXPLAIN SELECT /* priority_ordering_test */ * FROM test_orders WHERE customer_id = 42'
    LOOP
        plan_output := plan_output || rec."QUERY PLAN" || E'\n';
    END LOOP;

    -- High-priority rule (100) wins: index scans disabled → Seq Scan
    IF plan_output NOT LIKE '%Seq Scan%' THEN
        RAISE EXCEPTION 'Test 9 FAILED: expected Seq Scan (high-priority rule wins), got: %', plan_output;
    END IF;
    RAISE NOTICE 'Test 9 PASSED: highest priority rule wins';
END;
$$;

-- Cleanup
DELETE FROM plan_override.override_rules;
SELECT plan_override.refresh_cache();

-- ============================================================
-- Test 10: EXPLAIN ANALYZE confirms override applied at execution
-- ============================================================
DO $$
DECLARE
    rec             RECORD;
    baseline_plan   TEXT := '';
    override_plan   TEXT := '';
BEGIN
    -- Use a low-selectivity filter (matches ~99% of rows) so the optimizer
    -- naturally prefers Seq Scan, but an index on customer_id exists as
    -- an alternative when seq scan is disabled.

    -- Step 1: capture baseline plan (no overrides active)
    FOR rec IN EXECUTE
        'EXPLAIN ANALYZE SELECT /* analyze_execution_test */ * FROM test_orders WHERE customer_id > 0'
    LOOP
        baseline_plan := baseline_plan || rec."QUERY PLAN" || E'\n';
    END LOOP;

    IF baseline_plan NOT LIKE '%Seq Scan%' THEN
        RAISE EXCEPTION 'Test 10 FAILED: baseline plan expected Seq Scan, got: %', baseline_plan;
    END IF;

    -- Step 2: add override that disables seq scan
    PERFORM plan_override.add_by_pattern(
        '%analyze_execution_test%',
        '{"enable_seqscan": "off"}'::jsonb,
        'Test 10: explain analyze'
    );
    PERFORM plan_override.refresh_cache();

    -- Step 3: re-run with override — must switch away from Seq Scan
    FOR rec IN EXECUTE
        'EXPLAIN ANALYZE SELECT /* analyze_execution_test */ * FROM test_orders WHERE customer_id > 0'
    LOOP
        override_plan := override_plan || rec."QUERY PLAN" || E'\n';
    END LOOP;

    IF override_plan LIKE '%Seq Scan%' THEN
        RAISE EXCEPTION 'Test 10 FAILED: override plan still uses Seq Scan: %', override_plan;
    END IF;

    -- Must contain actual execution stats (proves query ran, not just planned)
    IF override_plan NOT LIKE '%actual time%' THEN
        RAISE EXCEPTION 'Test 10 FAILED: EXPLAIN ANALYZE missing execution stats: %', override_plan;
    END IF;

    RAISE NOTICE 'Test 10 PASSED: baseline used Seq Scan, override switched plan (EXPLAIN ANALYZE)';
END;
$$;

-- Cleanup
DELETE FROM plan_override.override_rules;
SELECT plan_override.refresh_cache();

-- ============================================================
-- Test 11: Non-matching query keeps default plan while rule active
-- ============================================================
DO $$
DECLARE
    rec             RECORD;
    matching_plan   TEXT := '';
    unmatched_plan  TEXT := '';
BEGIN
    -- Add a rule that only matches a specific comment tag
    PERFORM plan_override.add_by_pattern(
        '%only_this_query%',
        '{"enable_seqscan": "off"}'::jsonb,
        'Test 11: selective match'
    );
    PERFORM plan_override.refresh_cache();

    -- Matching query: should NOT use Seq Scan (override disables it)
    FOR rec IN EXECUTE
        'EXPLAIN SELECT /* only_this_query */ * FROM test_orders WHERE customer_id > 0'
    LOOP
        matching_plan := matching_plan || rec."QUERY PLAN" || E'\n';
    END LOOP;

    IF matching_plan LIKE '%Seq Scan%' THEN
        RAISE EXCEPTION 'Test 11 FAILED: matching query still uses Seq Scan: %', matching_plan;
    END IF;

    -- Non-matching query (full table scan, no WHERE): should use Seq Scan
    FOR rec IN EXECUTE
        'EXPLAIN SELECT /* different_query */ * FROM test_orders'
    LOOP
        unmatched_plan := unmatched_plan || rec."QUERY PLAN" || E'\n';
    END LOOP;

    IF unmatched_plan NOT LIKE '%Seq Scan%' THEN
        RAISE EXCEPTION 'Test 11 FAILED: non-matching query plan was altered: %', unmatched_plan;
    END IF;

    RAISE NOTICE 'Test 11 PASSED: non-matching query keeps default plan';
END;
$$;

-- Final cleanup
DELETE FROM plan_override.override_rules;
DROP TABLE test_orders;

\echo ''
\echo 'All 11 tests passed!'
