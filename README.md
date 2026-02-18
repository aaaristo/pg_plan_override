# pg_plan_override

Dynamic per-query planner GUC overrides for PostgreSQL 12+.

Intercepts the planner hook and applies GUC overrides (e.g. `enable_seqscan`, `work_mem`) to matching queries, then restores originals after planning completes. Queries are matched by `queryId` (exact) or `LIKE`-style pattern against the query text.

## Features

- **Pattern matching** — `%` and `_` wildcards against query text
- **queryId matching** — exact match for fingerprinted queries (requires `pg_stat_statements` on PG12-13, native on PG14+)
- **Priority ordering** — highest priority rule wins when multiple rules match
- **GUC restoration** — originals are restored after planning, even on error
- **In-memory cache** — rules loaded via SPI with configurable TTL
- **Master switch** — `pg_plan_override.enabled` to disable all overrides instantly

## Installation

### From source (requires PostgreSQL dev headers)

```bash
make
make install
```

### With Docker

```bash
docker-compose build build
docker-compose run --rm build
```

## Configuration

Add to `postgresql.conf`:

```
shared_preload_libraries = 'pg_plan_override'
```

Then create the extension:

```sql
CREATE EXTENSION pg_plan_override;
```

### GUC parameters

| Parameter | Default | Description |
|---|---|---|
| `pg_plan_override.enabled` | `on` | Master switch — disables all overrides when `off` |
| `pg_plan_override.debug` | `off` | Log when overrides are applied |
| `pg_plan_override.cache_ttl` | `60` | Seconds between rule cache refreshes (1–3600) |

## Usage

### Add a rule by pattern

```sql
SELECT plan_override.add_by_pattern(
    '%slow_report%',
    '{"work_mem": "256MB", "enable_seqscan": "off"}'::jsonb,
    'Speed up slow report query'
);
```

### Add a rule by queryId

```sql
SELECT plan_override.add_by_query_id(
    -6543210987654321,
    '{"enable_nestloop": "off"}'::jsonb,
    'Force hash join for this query'
);
```

### Manage rules

```sql
-- View all rules
SELECT * FROM plan_override.override_rules;

-- Disable a rule
UPDATE plan_override.override_rules SET enabled = false WHERE id = 1;

-- Force immediate cache refresh (otherwise waits for TTL expiry)
SELECT plan_override.refresh_cache();
```

### Quick disable (no restart needed)

```sql
SET pg_plan_override.enabled = off;
```

## Schema

The `plan_override.override_rules` table:

| Column | Type | Description |
|---|---|---|
| `id` | `serial` | Primary key |
| `query_id` | `bigint` | Match by queryId (nullable) |
| `query_pattern` | `text` | Match by LIKE pattern (nullable) |
| `description` | `text` | Human-readable note |
| `gucs` | `jsonb` | Key-value pairs of GUC overrides |
| `enabled` | `boolean` | Whether the rule is active (default `true`) |
| `priority` | `integer` | Higher value wins (default `0`) |
| `created_at` | `timestamptz` | Auto-set on insert |

At least one of `query_id` or `query_pattern` must be set (enforced by check constraint).

## Building and testing

Source is volume-mounted into Docker containers — no image rebuild needed after code changes.

```bash
# One-time: build the build-environment image
docker-compose build build

# Compile extension (after code changes)
docker-compose run --rm build

# Run all 9 e2e tests
docker-compose up --abort-on-container-exit --exit-code-from test

# Cleanup
docker-compose down -v
```

Exit code 0 means all 9 tests passed. A non-zero exit code includes a descriptive error message from the failing test.

## Contributing

This project uses [Conventional Commits](https://www.conventionalcommits.org/). Format commit messages as `<type>: <description>`.

Common types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `build`.

## Compatibility

- PostgreSQL 12+ (tested against 12, builds on 14+ with the updated planner hook signature)
- The C code uses `#if PG_VERSION_NUM >= 140000` guards for the planner hook signature change introduced in PG14
