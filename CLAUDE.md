# pg_plan_override

PostgreSQL extension that intercepts the planner hook to apply per-query GUC overrides. Targets PostgreSQL 12+ with `#if PG_VERSION_NUM >= 140000` guards for the PG14 planner hook signature change.

## Project structure

```
src/
  pg_plan_override.c          # Extension C source (planner hook, SPI cache, pattern matching)
  pg_plan_override.control    # Extension metadata (schema = plan_override)
  pg_plan_override--1.0.sql   # SQL objects (override_rules table, helper functions)
  Makefile                    # PGXS-based build
test/
  e2e_tests.sql              # 10 DO-block tests with RAISE EXCEPTION assertions
  run_tests.sh               # Test entrypoint (waits for PG, runs psql)
Dockerfile.build              # Build environment image (postgres:12 + build-essential + pg-server-dev)
docker-compose.yml            # Three services: build, pg, test
.gitignore                    # Excludes build artifacts (*.o, *.so, *.bc)
```

Build artifacts (`*.o`, `*.so`, `*.bc`) appear in `src/` when `make` runs — excluded by .gitignore.

## Build and test

Source is volume-mounted into containers — no image rebuild needed after code changes.

```bash
# One-time: build the build-environment image
docker-compose build build

# Compile (after code changes)
docker-compose run --rm build

# Run e2e tests
docker-compose up --abort-on-container-exit --exit-code-from test

# Cleanup
docker-compose down -v
```

## Commit conventions

This project uses [Conventional Commits](https://www.conventionalcommits.org/). Format: `<type>: <description>`, e.g. `feat: add cache TTL configuration`, `fix: restore GUC on planner error`. Common types: `feat`, `fix`, `refactor`, `test`, `docs`, `chore`, `build`.

## Key conventions

- Extension installs into the `plan_override` schema (set in .control, `pg_` prefix is reserved)
- GUC names still use `pg_plan_override.*` prefix (e.g. `pg_plan_override.enabled`)
- Rules are stored in `plan_override.override_rules` and cached in memory with configurable TTL
- Pattern matching uses LIKE-style `%` and `_` wildcards against query text
- On PG12-13, pattern matching uses `debug_query_string`; on PG14+, uses the `query_string` parameter passed to the planner hook
- GUC overrides are only active during planning — the planner produces a plan influenced by the overrides, then GUCs are restored immediately. The executor runs the already-decided plan; it never sees the overridden values.
- GUCs are always restored after planning, even on error (PG_TRY/PG_CATCH)
- The `loading_rules` flag prevents reentrancy when SPI queries go through the planner hook
- `load_rules()` checks the catalog for the `override_rules` table before querying it, so the extension works safely with `shared_preload_libraries` before `CREATE EXTENSION` is run
