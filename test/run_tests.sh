#!/usr/bin/env bash
set -euo pipefail

export PGHOST="${PGHOST:-pg}"
export PGUSER="${PGUSER:-postgres}"
export PGDATABASE="${PGDATABASE:-postgres}"

echo "Waiting for PostgreSQL at ${PGHOST}..."
until pg_isready -h "$PGHOST" -U "$PGUSER" -q; do
    sleep 1
done

echo "PostgreSQL is ready. Running e2e tests..."
echo ""

psql -v ON_ERROR_STOP=1 -f /test/e2e_tests.sql

echo ""
echo "========================================="
echo "  All 9 tests passed!"
echo "========================================="
